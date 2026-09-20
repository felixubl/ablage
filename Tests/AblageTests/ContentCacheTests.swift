import CoreGraphics
import ImageIO
import XCTest
@testable import Ablage

final class ContentCacheTests: XCTestCase {
    private var url: URL!
    private var facts: FileFacts!
    override func setUpWithError() throws {
        url = URL(fileURLWithPath: "/private/tmp/ablage-cache-\(UUID().uuidString).png")
        try Data("fixture".utf8).write(to: url)
        facts = try XCTUnwrap(FileFacts(url: url))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: url) }

    func testRecognitionPolicyIsPartOfCacheIdentity() {
        var calls = 0
        let cache = ContentCache { _, config, _ in
            calls += 1
            return .init(text: config.ocr ? "recognized \(config.ocrPages)" : "", ocrPending: false)
        }
        var config = Config(); config.ocr = false
        XCTAssertEqual(cache.text(for: facts, config: config, allowOCR: false), "")
        config.ocr = true
        XCTAssertEqual(cache.text(for: facts, config: config, allowOCR: true), "recognized 2")
        config.ocrPages = 4
        XCTAssertEqual(cache.text(for: facts, config: config, allowOCR: true), "recognized 4")
        config.ocrMaxMB += 10
        _ = cache.text(for: facts, config: config, allowOCR: true)
        XCTAssertEqual(calls, 4)
    }

    func testTinyValidImageDoesNotBecomeARecognitionFailure() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let facts = try XCTUnwrap(FileFacts(url: url))
        for allowOCR in [false, true] {
            let result = try XCTUnwrap(Extract.text(of: url, ext: "png", size: facts.size, config: Config(), allowOCR: allowOCR))
            XCTAssertEqual(result.text, "")
            XCTAssertNil(result.failure)
            XCTAssertFalse(result.ocrPending)
        }
    }

    func testLateQuickPreviewCannotEraseRecognizedText() {
        let began = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let preview = expectation(description: "Late preview completes")
        let cache = ContentCache { _, _, allowOCR in
            if allowOCR { return .init(text: "Invoice", ocrPending: false) }
            began.signal(); _ = finish.wait(timeout: .now() + 3)
            return .init(text: "", ocrPending: true)
        }
        let facts = self.facts!
        DispatchQueue.global().async {
            XCTAssertEqual(cache.text(for: facts, config: Config(), allowOCR: false), "Invoice")
            preview.fulfill()
        }
        XCTAssertEqual(began.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(cache.text(for: facts, config: Config(), allowOCR: true), "Invoice")
        finish.signal(); wait(for: [preview], timeout: 3)
        XCTAssertFalse(cache.ocrPending(cache.key(for: facts, config: Config())))
    }

    func testConcurrentRecognitionRunsOnceEvenWithAQuickPreview() {
        let began = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let done = expectation(description: "Both recognition readers complete"); done.expectedFulfillmentCount = 2
        let countLock = NSLock()
        var calls = 0
        let cache = ContentCache { _, _, allowOCR in
            if !allowOCR { return .init(text: "", ocrPending: true) }
            countLock.lock(); calls += 1; countLock.unlock()
            began.signal(); _ = finish.wait(timeout: .now() + 3)
            return .init(text: "Invoice", ocrPending: false)
        }
        let facts = self.facts!
        DispatchQueue.global().async { _ = cache.text(for: facts, config: Config(), allowOCR: true); done.fulfill() }
        XCTAssertEqual(began.wait(timeout: .now() + 3), .success)
        _ = cache.text(for: facts, config: Config(), allowOCR: false)
        DispatchQueue.global().async { _ = cache.text(for: facts, config: Config(), allowOCR: true); done.fulfill() }
        finish.signal(); wait(for: [done], timeout: 3)
        XCTAssertEqual(calls, 1)
    }

    func testFailureIsRetainedUntilExplicitRetry() {
        var attempts = 0
        let cache = ContentCache { _, _, _ in
            attempts += 1
            return attempts == 1 ? .init(text: "", ocrPending: false, failure: "Unavailable") : .init(text: "Invoice", ocrPending: false)
        }
        let key = cache.key(for: facts, config: Config())
        _ = cache.text(for: facts, config: Config(), allowOCR: true)
        _ = cache.text(for: facts, config: Config(), allowOCR: false)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(cache.failure(key), "Unavailable")
        cache.retryFailure(key)
        XCTAssertEqual(cache.text(for: facts, config: Config(), allowOCR: true), "Invoice")
        XCTAssertNil(cache.failure(key))
    }
}
