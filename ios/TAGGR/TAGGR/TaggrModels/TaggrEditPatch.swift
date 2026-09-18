// TAGGR/TaggrModels: Builds diff-match-patch compatible edit history patches without adding a dependency.

import Foundation

enum TaggrEditPatch {
    static func fullReplacement(from newText: String, to oldText: String) -> String {
        let newRange = range(for: newText)
        let oldRange = range(for: oldText)
        var patch = "@@ -\(newRange) +\(oldRange) @@\n"
        if !newText.isEmpty {
            patch += "-\(escape(newText))\n"
        }
        if !oldText.isEmpty {
            patch += "+\(escape(oldText))\n"
        }
        return patch
    }

    static func apply(_ patchText: String, to text: String) throws -> String {
        var result = text
        var delta = 0
        let patches = try parse(patchText)
        guard !patches.isEmpty else {
            throw TaggrEditPatchError.malformedPatch
        }
        for patch in patches {
            let sourceOffset = patch.sourceStart + delta
            guard let lowerBound = stringIndex(in: result, utf16Offset: sourceOffset),
                  let upperBound = stringIndex(in: result, utf16Offset: sourceOffset + patch.sourceLength) else {
                throw TaggrEditPatchError.sourceMismatch
            }
            let range = lowerBound..<upperBound
            guard String(result[range]) == patch.sourceText else {
                throw TaggrEditPatchError.sourceMismatch
            }
            result.replaceSubrange(range, with: patch.replacementText)
            delta += patch.replacementText.utf16.count - patch.sourceLength
        }
        return result
    }

    private static func range(for text: String) -> String {
        let length = text.utf16.count
        if length == 0 { return "0,0" }
        if length == 1 { return "1" }
        return "1,\(length)"
    }

    private static func escape(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'();/?:@&=+$,# ")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static func parse(_ patchText: String) throws -> [Patch] {
        let lines = patchText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var patches: [Patch] = []
        var index = 0
        while index < lines.count {
            guard !lines[index].isEmpty else {
                index += 1
                continue
            }
            let header = try parseHeader(lines[index])
            index += 1
            var sourceText = ""
            var replacementText = ""
            while index < lines.count, !lines[index].hasPrefix("@@ ") {
                let line = lines[index]
                guard let marker = line.first, [" ", "-", "+"].contains(marker) else {
                    if line.isEmpty, index == lines.count - 1 {
                        break
                    }
                    throw TaggrEditPatchError.malformedPatch
                }
                let encoded = String(line.dropFirst())
                guard let decoded = encoded.removingPercentEncoding else {
                    throw TaggrEditPatchError.malformedPatch
                }
                if marker != "+" {
                    sourceText += decoded
                }
                if marker != "-" {
                    replacementText += decoded
                }
                index += 1
            }
            guard sourceText.utf16.count == header.length else {
                throw TaggrEditPatchError.malformedPatch
            }
            patches.append(Patch(
                sourceStart: header.start,
                sourceLength: header.length,
                sourceText: sourceText,
                replacementText: replacementText
            ))
        }
        return patches
    }

    private static func parseHeader(_ line: String) throws -> (start: Int, length: Int) {
        guard line.hasPrefix("@@ -"), line.hasSuffix(" @@") else {
            throw TaggrEditPatchError.malformedPatch
        }
        let body = String(line.dropFirst(4).dropLast(3))
        let parts = body.split(separator: " ")
        guard parts.count == 2, parts[1].hasPrefix("+") else {
            throw TaggrEditPatchError.malformedPatch
        }
        _ = try parseRange(String(parts[1].dropFirst()))
        return try parseRange(String(parts[0]))
    }

    private static func parseRange(_ text: String) throws -> (start: Int, length: Int) {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              let rawStart = Int(parts[0]),
              rawStart >= 0 else {
            throw TaggrEditPatchError.malformedPatch
        }
        let length: Int
        if parts.count == 1 {
            length = 1
        } else {
            guard let parsedLength = Int(parts[1]), parsedLength >= 0 else {
                throw TaggrEditPatchError.malformedPatch
            }
            length = parsedLength
        }
        let start = length == 0 ? rawStart : rawStart - 1
        guard start >= 0 else {
            throw TaggrEditPatchError.malformedPatch
        }
        return (start, length)
    }

    private static func stringIndex(in text: String, utf16Offset: Int) -> String.Index? {
        guard utf16Offset >= 0, utf16Offset <= text.utf16.count else { return nil }
        let index = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset)
        return String.Index(index, within: text)
    }

    private struct Patch {
        let sourceStart: Int
        let sourceLength: Int
        let sourceText: String
        let replacementText: String
    }
}

enum TaggrEditPatchError: LocalizedError {
    case malformedPatch
    case sourceMismatch

    var errorDescription: String? {
        switch self {
        case .malformedPatch:
            return "The post edit history could not be decoded."
        case .sourceMismatch:
            return "The post edit history does not match the current post body."
        }
    }
}
