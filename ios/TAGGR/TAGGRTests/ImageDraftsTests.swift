import ImageIO
import Darwin
import UniformTypeIdentifiers
import UIKit
import XCTest
import libwebp
@testable import TAGGR

extension TaggrTests {
    // Run explicitly with optimized app/test targets; prints raw samples for repeatable comparisons.
    func testPostImageCompressionBenchmark() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TAGGR_IMAGE_BENCHMARK"] == "1")
        var fixtures = try ["taggr-12mp", "taggr-24mp", "taggr-48mp", "gull"].map { name in
            (name, try fixtureData(named: name))
        }
        fixtures.append(("noise-2mp", try noisyPNG(width: 1600, height: 1200)))
        for (name, input) in fixtures {
            _ = try ImageDrafts.postImageResult(from: input, maxBytes: ImageDrafts.maxPostImageBytes).get()
            for sample in 0..<5 {
                let start = ContinuousClock.now
                let image = try ImageDrafts.postImageResult(from: input, maxBytes: ImageDrafts.maxPostImageBytes).get()
                let elapsed = start.duration(to: .now)
                print("IMAGE_BENCH pipeline \(name) sample=\(sample) ms=\(milliseconds(elapsed)) bytes=\(image.data.count) id=\(image.id) width=\(image.width) height=\(image.height)")
                XCTAssertLessThanOrEqual(image.data.count, ImageDrafts.maxPostImageBytes)
            }
        }
        let inputs = fixtures.map(\.1)
        for concurrency in [2, 3, 4] {
            for sample in 0..<3 {
                let start = ContinuousClock.now
                let result = await ImageDrafts.importImages(count: inputs.count, maxConcurrent: concurrency) { inputs[$0] }
                let elapsed = start.duration(to: .now)
                XCTAssertTrue(result.failures.isEmpty)
                XCTAssertEqual(result.images.count, inputs.count)
                print("IMAGE_BENCH batch concurrency=\(concurrency) sample=\(sample) ms=\(milliseconds(elapsed))")
            }
        }
    }

    // Run each concurrency/workload in a fresh process: the kernel peak is process-wide.
    func testImageImportConcurrencyBenchmark() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TAGGR_IMAGE_BENCHMARK"] == "1")
        let useDefault = ProcessInfo.processInfo.environment["TAGGR_IMAGE_USE_DEFAULT"] == "1"
        let concurrency = useDefault ? ImageDrafts.defaultImportConcurrency
            : try XCTUnwrap(Int(ProcessInfo.processInfo.environment["TAGGR_IMAGE_CONCURRENCY"] ?? "2"))
        XCTAssertTrue((2...4).contains(concurrency))
        let workload = ProcessInfo.processInfo.environment["TAGGR_IMAGE_WORKLOAD"] ?? "mixed"
        let environment = "IMAGE_PARALLEL_ENV os=\(UIDevice.current.systemVersion) processors=\(ProcessInfo.processInfo.processorCount) physical_memory_bytes=\(ProcessInfo.processInfo.physicalMemory) low_power=\(ProcessInfo.processInfo.isLowPowerModeEnabled) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) webp_version=\(WebPGetEncoderVersion()) default_concurrency=\(ImageDrafts.defaultImportConcurrency) use_default=\(useDefault)"
        print(environment)
        var records = [environment]
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("image-concurrency-\(workload)-\(concurrency).log")
        try environment.write(to: output, atomically: true, encoding: .utf8)
        let inputs: [Data]
        switch workload {
        case "photo8":
            inputs = Array(repeating: try fixtureData(named: "gull"), count: 8)
        case "48mp8":
            inputs = Array(repeating: try fixtureData(named: "taggr-48mp"), count: 8)
        default:
            inputs = try ["taggr-12mp", "taggr-24mp", "taggr-48mp", "gull"].map { try fixtureData(named: $0) }
                + [noisyPNG(width: 1600, height: 1200)]
        }
        let initialMemory = try imageBenchmarkMemory()
        let reference = await ImageDrafts.importImages(count: inputs.count, maxConcurrent: 1) { inputs[$0] }
        XCTAssertTrue(reference.failures.isEmpty)
        let expectedIDs = reference.images.map(\.id)
        for sample in 0..<5 {
            let start = ContinuousClock.now
            let result: ImageImportBatchResult
            if useDefault {
                result = await ImageDrafts.importImages(count: inputs.count) { inputs[$0] }
            } else {
                result = await ImageDrafts.importImages(count: inputs.count, maxConcurrent: concurrency) { inputs[$0] }
            }
            let elapsed = start.duration(to: .now)
            let memory = try imageBenchmarkMemory()
            XCTAssertTrue(result.failures.isEmpty)
            XCTAssertEqual(result.images.map(\.id), expectedIDs)
            XCTAssertEqual(result.images.count, inputs.count)
            for image in result.images {
                XCTAssertLessThanOrEqual(image.data.count, ImageDrafts.maxPostImageBytes)
                XCTAssertLessThanOrEqual(image.width * image.height, ImageDrafts.maxPostImagePixels)
            }
            let record = "IMAGE_PARALLEL workload=\(workload) concurrency=\(concurrency) sample=\(sample) ms=\(milliseconds(elapsed)) footprint_bytes=\(memory.footprint) peak_footprint_bytes=\(memory.peakFootprint) resident_bytes=\(memory.resident) peak_resident_bytes=\(memory.peakResident) baseline_footprint_bytes=\(initialMemory.footprint) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)"
            print(record)
            records.append(record)
            try records.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
        }
    }

    private func imageBenchmarkMemory() throws -> (footprint: UInt64, peakFootprint: Int64, resident: UInt64, peakResident: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw NSError(domain: NSMachErrorDomain, code: Int(status)) }
        return (info.phys_footprint, info.ledger_phys_footprint_peak, info.resident_size, info.resident_size_peak)
    }

    func testWebPEncoderMethodBenchmark() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TAGGR_IMAGE_BENCHMARK"] == "1")
        for name in ["taggr-12mp", "taggr-24mp", "taggr-48mp", "gull"] {
            let input = try fixtureData(named: name)
            let (image, rgba) = try postImageTestPixels(input)
            for (method, threads): (Int32, Int32) in [(0, 0), (1, 0), (2, 0), (3, 0), (4, 0), (4, 1)] {
                _ = try benchmarkWebP(rgba, width: image.width, height: image.height, method: method, threads: threads)
                for sample in 0..<5 {
                    let start = ContinuousClock.now
                    let output = try benchmarkWebP(rgba, width: image.width, height: image.height, method: method, threads: threads)
                    let elapsed = start.duration(to: .now)
                    XCTAssertNotNil(UIImage(data: output))
                    print("IMAGE_BENCH encoder \(name) method=\(method) threads=\(threads) sample=\(sample) ms=\(milliseconds(elapsed)) bytes=\(output.count)")
                    if sample == 0 {
                        let ssim = try benchmarkSSIM(output, rgba: rgba, width: image.width, height: image.height)
                        print("IMAGE_BENCH quality \(name) method=\(method) threads=\(threads) ssim_db=\(ssim)")
                    }
                }
            }
        }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private func benchmarkWebP(_ rgba: Data, width: Int, height: Int, method: Int32, threads: Int32) throws -> Data {
        var config = WebPConfig()
        XCTAssertNotEqual(WebPConfigPreset(&config, WEBP_PRESET_DEFAULT, Float(ImageDrafts.postImageWebPQuality)), 0)
        config.method = method
        config.thread_level = threads
        var picture = WebPPicture()
        XCTAssertNotEqual(WebPPictureInit(&picture), 0)
        defer { WebPPictureFree(&picture) }
        picture.width = Int32(width)
        picture.height = Int32(height)
        picture.writer = WebPMemoryWrite
        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }
        return try withUnsafeMutablePointer(to: &writer) { writerPointer in
            picture.custom_ptr = UnsafeMutableRawPointer(writerPointer)
            let imported = rgba.withUnsafeBytes { buffer in
                WebPPictureImportRGBA(&picture, buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), Int32(width * 4))
            }
            XCTAssertNotEqual(imported, 0)
            XCTAssertNotEqual(WebPEncode(&config, &picture), 0)
            return Data(bytes: try XCTUnwrap(writerPointer.pointee.mem), count: writerPointer.pointee.size)
        }
    }

    private func postImageTestPixels(_ input: Data) throws -> (CGImage, Data) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(input as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2000,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary))
        var rgba = Data(count: image.width * image.height * 4)
        try rgba.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (image, rgba)
    }

    private func benchmarkSSIM(_ output: Data, rgba: Data, width: Int, height: Int) throws -> Float {
        var decodedWidth: Int32 = 0
        var decodedHeight: Int32 = 0
        let decoded = try output.withUnsafeBytes { buffer in
            try XCTUnwrap(WebPDecodeRGBA(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), output.count, &decodedWidth, &decodedHeight))
        }
        defer { WebPFree(decoded) }
        XCTAssertEqual(Int(decodedWidth), width)
        XCTAssertEqual(Int(decodedHeight), height)
        var reference = WebPPicture()
        var compressed = WebPPicture()
        XCTAssertNotEqual(WebPPictureInit(&reference), 0)
        XCTAssertNotEqual(WebPPictureInit(&compressed), 0)
        defer { WebPPictureFree(&reference); WebPPictureFree(&compressed) }
        reference.width = Int32(width)
        reference.height = Int32(height)
        reference.use_argb = 1
        compressed.width = Int32(width)
        compressed.height = Int32(height)
        compressed.use_argb = 1
        let imported = rgba.withUnsafeBytes { buffer in
            WebPPictureImportRGBA(&reference, buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), Int32(width * 4))
        }
        XCTAssertNotEqual(imported, 0)
        XCTAssertNotEqual(WebPPictureImportRGBA(&compressed, decoded, Int32(width * 4)), 0)
        var distortion = [Float](repeating: 0, count: 5)
        XCTAssertNotEqual(WebPPictureDistortion(&compressed, &reference, 1, &distortion), 0)
        return distortion[4]
    }

    @MainActor
    func testImageImportCoordinatorDropsCancelledAndSupersededResults() async {
        let coordinator = ImageImportCoordinator()
        let oldGate = ImageImportTestGate()
        let oldStarted = expectation(description: "old import started")
        var completedIndices: [Int] = []
        let old = coordinator.start(count: 3, operation: { onProgress in
            oldStarted.fulfill()
            await oldGate.wait()
            await onProgress(ImageImportProgress(completed: 3, total: 3))
            return ImageImportBatchResult(images: [], failures: [.init(index: 1, reason: .photoReadFailed)])
        }, completion: { result in completedIndices.append(contentsOf: result.failures.map(\.index)) })
        await fulfillment(of: [oldStarted], timeout: 1)
        let latest = coordinator.start(count: 2, operation: { onProgress in
            await onProgress(ImageImportProgress(completed: 2, total: 2))
            return ImageImportBatchResult(images: [], failures: [.init(index: 2, reason: .photoReadFailed)])
        }, completion: { result in completedIndices.append(contentsOf: result.failures.map(\.index)) })
        await latest.value
        await oldGate.open()
        await old.value
        XCTAssertEqual(completedIndices, [2])
        XCTAssertFalse(coordinator.isImporting)
        XCTAssertEqual(coordinator.progress, ImageImportProgress(completed: 2, total: 2))

        let cancelledGate = ImageImportTestGate()
        let cancelledStarted = expectation(description: "cancelled import started")
        let cancelled = coordinator.start(operation: { _ in
            cancelledStarted.fulfill()
            await cancelledGate.wait()
            return ImageImportBatchResult(images: [], failures: [])
        }, completion: { _ in XCTFail("Cancelled import updated the editor") })
        await fulfillment(of: [cancelledStarted], timeout: 1)
        coordinator.cancel()
        await cancelledGate.open()
        await cancelled.value
        XCTAssertFalse(coordinator.isImporting)
        XCTAssertEqual(coordinator.progress, ImageImportProgress(completed: 0, total: 0))
    }

    func testImageImportReportsProgressIncludingFailedImages() async {
        let coordinator = ImageImportCoordinator()
        let loaded = expectation(description: "loading first image")
        let gate = ImageImportTestGate()
        let recorder = ImageImportProgressRecorder()
        let task = coordinator.start(count: 3, operation: { onProgress in
            await ImageDrafts.importImages(count: 3, maxConcurrent: 1, onProgress: { progress in
                await recorder.record(progress)
                await onProgress(progress)
            }) { index in
                if index == 0 {
                    loaded.fulfill()
                    await gate.wait()
                }
                return nil
            }
        }, completion: { result in
            XCTAssertEqual(result.failures.count, 3)
        })
        await fulfillment(of: [loaded], timeout: 1)
        XCTAssertTrue(coordinator.isImporting)
        XCTAssertEqual(coordinator.progress, ImageImportProgress(completed: 0, total: 3))
        await gate.open()
        await task.value
        let updates = await recorder.updates
        XCTAssertEqual(updates, (0...3).map { ImageImportProgress(completed: $0, total: 3) })
        XCTAssertFalse(coordinator.isImporting)
    }

    func testClipboardImageImportPreservesOrderAndReportsPartialFailure() async throws {
        let wide = solidPNG(width: 12, height: 8)
        let tall = solidPNG(width: 6, height: 10)
        let operation = ImageDrafts.itemProviderImportOperation(
            [imageProvider(wide), imageProvider(Data("invalid".utf8)), imageProvider(tall)]
        )
        let result = await operation(ImageDrafts.maxPostImageBytes, { _ in })

        XCTAssertEqual(result.images.map { [$0.width, $0.height] }, [[12, 8], [6, 10]])
        XCTAssertEqual(result.failures, [ImageImportFailure(index: 1, reason: .invalidImage)])
    }

    @MainActor
    func testClipboardImageImportCancelsProviderLoad() async {
        let started = expectation(description: "provider load started")
        let cancelled = expectation(description: "provider load cancelled")
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            started.fulfill()
            let progress = Progress(totalUnitCount: 1)
            progress.cancellationHandler = {
                cancelled.fulfill()
                completion(nil, CancellationError())
            }
            return progress
        }
        let operation = ImageDrafts.itemProviderImportOperation([provider])

        let task = Task {
            await operation(ImageDrafts.maxPostImageBytes, { _ in })
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        _ = await task.value
    }

    func testPostWebPUsesQuality50AndRequestsResizingInsteadOfLoweringQuality() {
        var qualities: [Int] = []
        let fits = ImageDrafts.postWebP(maxBytes: 51) { quality in
            qualities.append(quality)
            return Data(count: quality + 1)
        }
        guard case .fit(let data) = fits else {
            return XCTFail("Quality 50 should fit at the exact size limit.")
        }
        XCTAssertEqual(data.count, 51)
        XCTAssertEqual(qualities, [50])

        qualities = []
        let oversized = ImageDrafts.postWebP(maxBytes: 50) { quality in
            qualities.append(quality)
            return Data(count: quality + 1)
        }
        guard case .tooLarge(51) = oversized else {
            return XCTFail("Oversize quality 50 output should request resizing.")
        }
        XCTAssertEqual(qualities, [50])

        let failed = ImageDrafts.postWebP(maxBytes: 51) { _ in nil }
        guard case .failed = failed else {
            return XCTFail("Encoding failure should be preserved.")
        }
    }

    func testPostImagesNormalizeHighResolutionFixturesToWebP() throws {
        for fixture in ["taggr-12mp", "taggr-24mp", "taggr-48mp"] {
            let input = try fixtureData(named: fixture)
            let draft = try ImageDrafts.postImageResult(from: input, maxBytes: ImageDrafts.maxPostImageBytes).get()

            XCTAssertTrue(isWebP(draft.data), fixture)
            XCTAssertLessThanOrEqual(draft.data.count, ImageDrafts.maxPostImageBytes, fixture)
            XCTAssertLessThanOrEqual(draft.width * draft.height, ImageDrafts.maxPostImagePixels, fixture)
            XCTAssertNotNil(UIImage(data: draft.data), fixture)
            XCTAssertEqual(draft.id, ImageDrafts.blobId(for: draft.data), fixture)
        }
    }

    func testPostImageMaximumBytesUsesTheSmallerOfLocalAndServerLimits() {
        XCTAssertEqual(
            ImageDrafts.postImageMaximumBytes(serverLimit: nil),
            ImageDrafts.maxPostImageBytes
        )
        XCTAssertEqual(
            ImageDrafts.postImageMaximumBytes(serverLimit: 460_800),
            ImageDrafts.maxPostImageBytes
        )
        XCTAssertEqual(
            ImageDrafts.postImageMaximumBytes(serverLimit: 100 * 1_024),
            100 * 1_024
        )
    }

    func testSmallJPEGAndPNGAreBothReencodedAsWebP() throws {
        let image = try XCTUnwrap(solidImage(width: 32, height: 24, color: (20, 80, 200, 255)))
        let png = try XCTUnwrap(UIImage(cgImage: image).pngData())
        let jpeg = try XCTUnwrap(UIImage(cgImage: image).jpegData(compressionQuality: 0.9))

        for input in [jpeg, png] {
            let draft = try ImageDrafts.postImageResult(from: input, maxBytes: ImageDrafts.maxPostImageBytes).get()
            XCTAssertTrue(isWebP(draft.data))
            XCTAssertNotEqual(draft.data, input)
            XCTAssertEqual(draft.width, 32)
            XCTAssertEqual(draft.height, 24)
        }
    }

    func testOriginalHEICPhotoIsReencodedAsWebP() throws {
        let image = try XCTUnwrap(solidImage(width: 32, height: 24, color: (20, 80, 200, 255)))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let draft = try ImageDrafts.postImageResult(from: data as Data, maxBytes: ImageDrafts.maxPostImageBytes).get()
        XCTAssertTrue(isWebP(draft.data))
        XCTAssertEqual(draft.width, 32)
        XCTAssertEqual(draft.height, 24)
        XCTAssertLessThanOrEqual(draft.data.count, ImageDrafts.maxPostImageBytes)
    }

    func testPostImageShrinksDimensionsWhenQuality50ExceedsLimit() throws {
        let source = try noisyPNG(width: 128, height: 128)
        let draft = try ImageDrafts.postImageResult(from: source, maxBytes: 800).get()

        XCTAssertTrue(isWebP(draft.data))
        XCTAssertLessThanOrEqual(draft.data.count, 800)
        XCTAssertLessThan(draft.width, 128)
        XCTAssertLessThan(draft.height, 128)
        XCTAssertEqual(Double(draft.width) / Double(draft.height), 1, accuracy: 0.02)
    }

    func testPostImageKeepsResolutionWhenFasterEncodingExceedsSizeLimit() throws {
        let input = try fixtureData(named: "gull")
        let (image, rgba) = try postImageTestPixels(input)
        let original = try benchmarkWebP(rgba, width: image.width, height: image.height, method: 4, threads: 0)
        let fast = try benchmarkWebP(rgba, width: image.width, height: image.height, method: 2, threads: 0)
        XCTAssertGreaterThan(fast.count, original.count)

        let draft = try ImageDrafts.postImageResult(from: input, maxBytes: original.count).get()
        XCTAssertEqual(draft.width, image.width)
        XCTAssertEqual(draft.height, image.height)
        XCTAssertEqual(draft.data, original)
    }

    func testEXIFOrientationIsAppliedAndMetadataIsNotCopied() throws {
        let source = try orientedJPEG()
        let draft = try ImageDrafts.postImageResult(from: source, maxBytes: ImageDrafts.maxPostImageBytes).get()

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

        let draft = try ImageDrafts.postImageResult(from: source, maxBytes: ImageDrafts.maxPostImageBytes).get()
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
            "2 images could not be attached: 1 could not be read; 1 could not be converted to WebP."
        )
    }

    private func fixtureData(named name: String) throws -> Data {
        let bundle = Bundle(for: TaggrTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "jpg", subdirectory: "Fixtures")
        )
        return try Data(contentsOf: url)
    }

    private func imageProvider(_ data: Data) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
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

private actor ImageImportProgressRecorder {
    private(set) var updates: [ImageImportProgress] = []

    func record(_ progress: ImageImportProgress) {
        updates.append(progress)
    }
}

private actor ImageImportTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
