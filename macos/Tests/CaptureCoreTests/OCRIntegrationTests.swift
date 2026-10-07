import XCTest
import AppKit
@testable import CaptureCore

final class OCRIntegrationTests: XCTestCase {
    func testRealVisionOutputAndJPEGSurviveStorage() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("contextcap-ocr-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 600, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1200, height: 600)).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black]
        ("Invoice 1234" as NSString).draw(at: NSPoint(x: 40, y: 420), withAttributes: attributes)
        ("日本語の記録テスト" as NSString).draw(at: NSPoint(x: 40, y: 280), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        let (jpeg, text) = try ImageRecognizer.recognize(XCTUnwrap(bitmap.cgImage))
        XCTAssertTrue(text.contains("Invoice 1234"), text)
        XCTAssertTrue(text.contains("日本語の記録テスト"), text)
        XCTAssertNotNil(NSImage(data: jpeg))
        let archive = try Archive(root: root)
        try archive.save(image: jpeg, text: text, at: Date(), retentionDays: 3)
        XCTAssertEqual(try archive.latest()?.image, jpeg)
        XCTAssertEqual(try archive.latest()?.text, text)
        XCTAssertEqual(try archive.count(), 1)
    }
}
