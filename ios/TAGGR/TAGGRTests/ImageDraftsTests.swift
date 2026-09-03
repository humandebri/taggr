import ImageIO
import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import TAGGR

extension TaggrTests {
    @MainActor
    func testImageImportCoordinatorDropsCancelledAndSupersededResults() async {
        let coordinator = ImageImportCoordinator()
        var completedIndices: [Int] = []
        let latestCompleted = expectation(description: "latest import completed")

        coordinator.start(
            operation: {
                try? await Task.sleep(for: .milliseconds(100))
                return ImageImportBatchResult(
                    images: [],
                    failures: [ImageImportFailure(index: 1, reason: .photoReadFailed)]
                )
            },
            completion: { result in
                completedIndices.append(contentsOf: result.failures.map(\.index))
            }
        )
        coordinator.start(
            operation: {
                ImageImportBatchResult(
                    images: [],
                    failures: [ImageImportFailure(index: 2, reason: .photoReadFailed)]
                )
            },
            completion: { result in
                completedIndices.append(contentsOf: result.failures.map(\.index))
                latestCompleted.fulfill()
            }
        )

        await fulfillment(of: [latestCompleted], timeout: 1)
        XCTAssertEqual(completedIndices, [2])
        XCTAssertFalse(coordinator.isImporting)

        let cancelledCompleted = expectation(description: "cancelled import did not complete")
        cancelledCompleted.isInverted = true
        coordinator.start(
            operation: {
                try? await Task.sleep(for: .milliseconds(100))
                return ImageImportBatchResult(images: [], failures: [])
            },
            completion: { _ in cancelledCompleted.fulfill() }
        )
        coordinator.cancel()

        await fulfillment(of: [cancelledCompleted], timeout: 0.2)
        XCTAssertFalse(coordinator.isImporting)
    }

    func testWebPQualitySearchShortCircuitsAndFindsHighestFit() {
        var qualities: [Int] = []
        let maximumFits = ImageDrafts.highestQualityWebP(maxBytes: 101) { quality in
            qualities.append(quality)
            return Data(count: quality + 1)
        }
        guard case .fit(let maximumData) = maximumFits else {
            return XCTFail("Quality 100 should fit.")
        }
        XCTAssertEqual(maximumData.count, 101)
        XCTAssertEqual(qualities, [0, 100])

        qualities = []
        let bounded = ImageDrafts.highestQualityWebP(maxBytes: 73) { quality in
            qualities.append(quality)
            return Data(count: quality + 1)
        }
        guard case .fit(let boundedData) = bounded else {
            return XCTFail("A bounded quality should fit.")
        }
        XCTAssertEqual(boundedData.count, 73)
        XCTAssertTrue(qualities.contains(72))

        qualities = []
        let impossible = ImageDrafts.highestQualityWebP(maxBytes: 0) { quality in
            qualities.append(quality)
            return Data(count: 1)
        }
        guard case .tooLarge(1) = impossible else {
            return XCTFail("Quality zero should report the oversize payload.")
        }
        XCTAssertEqual(qualities, [0])
    }

    func testPostImagesNormalizeHighResolutionFixturesToWebP() throws {
        for fixture in ["taggr-12mp", "taggr-24mp", "taggr-48mp"] {
            let input = try fixtureData(named: fixture)
            let draft = try XCTUnwrap(ImageDrafts.draftImage(from: input))

            XCTAssertTrue(isWebP(draft.data), fixture)
            XCTAssertLessThanOrEqual(draft.data.count, ImageDrafts.maxImageBytes, fixture)
            XCTAssertLessThanOrEqual(draft.width * draft.height, ImageDrafts.maxImagePixels, fixture)
            XCTAssertNotNil(UIImage(data: draft.data), fixture)
            XCTAssertEqual(draft.id, ImageDrafts.blobId(for: draft.data), fixture)
        }
    }

    func testSmallJPEGAndPNGAreBothReencodedAsWebP() throws {
        let image = try XCTUnwrap(solidImage(width: 32, height: 24, color: (20, 80, 200, 255)))
        let png = try XCTUnwrap(UIImage(cgImage: image).pngData())
        let jpeg = try XCTUnwrap(UIImage(cgImage: image).jpegData(compressionQuality: 0.9))

        for input in [jpeg, png] {
            let draft = try XCTUnwrap(ImageDrafts.draftImage(from: input))
            XCTAssertTrue(isWebP(draft.data))
            XCTAssertNotEqual(draft.data, input)
            XCTAssertEqual(draft.width, 32)
            XCTAssertEqual(draft.height, 24)
        }
    }

    func testPostImageShrinksDimensionsWhenQualityZeroStillExceedsLimit() throws {
        let source = try noisyPNG(width: 128, height: 128)
        let draft = try XCTUnwrap(ImageDrafts.draftImage(from: source, maxBytes: 800))

        XCTAssertTrue(isWebP(draft.data))
        XCTAssertLessThanOrEqual(draft.data.count, 800)
        XCTAssertLessThan(draft.width, 128)
        XCTAssertLessThan(draft.height, 128)
        XCTAssertEqual(Double(draft.width) / Double(draft.height), 1, accuracy: 0.02)
    }

    func testEXIFOrientationIsAppliedAndMetadataIsNotCopied() throws {
        let source = try orientedJPEG()
        let draft = try XCTUnwrap(ImageDrafts.draftImage(from: source))

        XCTAssertEqual(draft.width, 20)
        XCTAssertEqual(draft.height, 40)
        XCTAssertEqual(Double(draft.width) / Double(draft.height), 0.5, accuracy: 0.01)
        XCTAssertTrue(isWebP(draft.data))
        for marker in ["EXIF", "XMP ", "ICCP"] {
            XCTAssertNil(draft.data.range(of: Data(marker.utf8)), marker)
        }
    }

    func testTransparentPNGPreservesAlphaInWebP() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format)
        let source = try XCTUnwrap(renderer.image { context in
            UIColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 0.5).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }.pngData())

        let draft = try XCTUnwrap(ImageDrafts.draftImage(from: source))
        let decoded = try XCTUnwrap(UIImage(data: draft.data)?.cgImage)
        let pixel = try rgbaPixel(in: decoded, x: 8, y: 8)

        XCTAssertTrue(isWebP(draft.data))
        XCTAssertEqual(pixel[3], 128, accuracy: 3)
    }

    func testPostImageFailureReasonsAndWarningArePreserved() {
        guard case .failure(.invalidImage) = ImageDrafts.postImageResult(
            from: Data("not-an-image".utf8),
            maxBytes: ImageDrafts.maxImageBytes
        ) else {
            return XCTFail("Invalid input should report invalidImage.")
        }
        let image = solidPNG(width: 8, height: 8)
        guard case .failure(.sizeLimitUnreachable) = ImageDrafts.postImageResult(
            from: image,
            maxBytes: 1
        ) else {
            return XCTFail("An impossible size limit should be reported.")
        }

        let result = ImageImportBatchResult(
            images: [],
            failures: [
                ImageImportFailure(index: 3, reason: .photoReadFailed),
                ImageImportFailure(index: 1, reason: .webPEncodingFailed),
            ]
        )
        XCTAssertEqual(result.failures.map(\.index), [3, 1])
        XCTAssertEqual(
            result.warning,
            "2 images could not be attached: 1 could not be read from Photos; 1 could not be converted to WebP."
        )
    }

    private func fixtureData(named name: String) throws -> Data {
        let bundle = Bundle(for: TaggrTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "jpg", subdirectory: "Fixtures")
        )
        return try Data(contentsOf: url)
    }

    private func isWebP(_ data: Data) -> Bool {
        data.count >= 12
            && String(data: data.prefix(4), encoding: .ascii) == "RIFF"
            && String(data: data[8..<12], encoding: .ascii) == "WEBP"
    }

    private func orientedJPEG() throws -> Data {
        let image = try XCTUnwrap(solidImage(width: 40, height: 20, color: (220, 40, 30, 255)))
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        )
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private"],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 35.0,
                kCGImagePropertyGPSLatitudeRef: "N",
            ],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "private"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func noisyPNG(width: Int, height: Int) throws -> Data {
        var seed: UInt32 = 0x1234_5678
        var rgba = Data(count: width * height * 4)
        rgba.withUnsafeMutableBytes { buffer in
            let pixels = buffer.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                for channel in 0..<3 {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    pixels[offset + channel] = UInt8(truncatingIfNeeded: seed >> 16)
                }
                pixels[offset + 3] = 255
            }
        }
        let image = try XCTUnwrap(cgImage(width: width, height: height, rgba: rgba))
        return try XCTUnwrap(UIImage(cgImage: image).pngData())
    }

    private func solidPNG(width: Int, height: Int) -> Data {
        let image = solidImage(width: width, height: height, color: (255, 0, 0, 255))!
        return UIImage(cgImage: image).pngData()!
    }

    private func solidImage(
        width: Int,
        height: Int,
        color: (UInt8, UInt8, UInt8, UInt8)
    ) -> CGImage? {
        var rgba = Data(count: width * height * 4)
        rgba.withUnsafeMutableBytes { buffer in
            let pixels = buffer.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                pixels[offset] = color.0
                pixels[offset + 1] = color.1
                pixels[offset + 2] = color.2
                pixels[offset + 3] = color.3
            }
        }
        return cgImage(width: width, height: height, rgba: rgba)
    }

    private func cgImage(width: Int, height: Int, rgba: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: rgba as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.last.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func rgbaPixel(in image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(
            CGContext(
                data: &bytes,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.translateBy(x: CGFloat(-x), y: CGFloat(y - image.height + 1))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }
}
