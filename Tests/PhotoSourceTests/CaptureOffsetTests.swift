import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhotoSource

final class CaptureOffsetTests: XCTestCase {
    func testParsesCommonOffsetForms() {
        XCTAssertEqual(CaptureOffset.parse("+09:00"), 9 * 3600)
        XCTAssertEqual(CaptureOffset.parse("-0500"), -5 * 3600)
        XCTAssertEqual(CaptureOffset.parse("+05:30"), 19800)
        XCTAssertEqual(CaptureOffset.parse("Z"), 0)
        XCTAssertEqual(CaptureOffset.parse(" +08 "), 8 * 3600)
        XCTAssertNil(CaptureOffset.parse(""))
        XCTAssertNil(CaptureOffset.parse("Asia/Taipei"))
        XCTAssertNil(CaptureOffset.parse("+99:99"))
    }

    func testParsesQuickTimeCreationDate() {
        XCTAssertEqual(CaptureOffset.fromQuickTimeDate("2026-10-13T10:00:00+0800"), 8 * 3600)
        XCTAssertEqual(CaptureOffset.fromQuickTimeDate("2026-10-13T10:00:00-05:00"), -5 * 3600)
        XCTAssertEqual(CaptureOffset.fromQuickTimeDate("2026-10-13T10:00:00Z"), 0)
        XCTAssertNil(CaptureOffset.fromQuickTimeDate("2026-10-13T10:00:00"))
        XCTAssertNil(CaptureOffset.fromQuickTimeDate("garbage"))
    }

    private func jpeg(exif: [CFString: Any]?, side: Int = 4, type: UTType = .jpeg, noisy: Bool = false) throws -> Data {
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        if noisy {   // 雜訊壓不掉，檔案才會真的有數 MB，像相機拍的照片
            let buffer = ctx.data!.assumingMemoryBound(to: UInt8.self)
            var generator = SystemRandomNumberGenerator()
            for i in 0..<(ctx.bytesPerRow * side) { buffer[i] = UInt8.random(in: 0...255, using: &generator) }
        } else {
            for i in 0..<side {
                ctx.setFillColor(CGColor(red: CGFloat(i % 7) / 7, green: CGFloat(i % 11) / 11, blue: 0.3, alpha: 1))
                ctx.fill(CGRect(x: i, y: 0, width: 1, height: side))
            }
        }
        let image = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let exif { props[kCGImagePropertyExifDictionary] = exif }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    func testReadsOffsetTimeOriginalFromImageData() throws {
        let data = try jpeg(exif: [kCGImagePropertyExifOffsetTimeOriginal: "+09:00",
                                   kCGImagePropertyExifDateTimeOriginal: "2026:10:13 10:00:00"])
        XCTAssertEqual(CaptureOffset.fromImageData(data), 9 * 3600)
    }

    /// iPhone 的照片是 HEIC。完整的 HEIC 用「資料還沒收完」的增量模式讀不到 EXIF，實機模擬器上實測過。
    func testReadsOffsetFromHEICData() throws {
        let data = try jpeg(exif: [kCGImagePropertyExifOffsetTimeOriginal: "+09:00"], side: 300, type: .heic)
        XCTAssertEqual(CaptureOffset.fromImageData(data), 9 * 3600)
    }

    /// 相機照片是數 MB。App 只收串流的開頭（64 KB～1 MB），所以要確認只有開頭一段也讀得到。
    func testReadsOffsetFromOnlyTheStartOfALargeHEIC() throws {
        let data = try jpeg(exif: [kCGImagePropertyExifOffsetTimeOriginal: "+09:00"], side: 2600, type: .heic, noisy: true)
        XCTAssertGreaterThan(data.count, 2_000_000, "測試檔太小，沒測到重點")
        XCTAssertEqual(CaptureOffset.fromImageData(data.prefix(64 * 1024)), 9 * 3600, "64 KB")
        XCTAssertEqual(CaptureOffset.fromImageData(data.prefix(1024 * 1024)), 9 * 3600, "1 MB")
    }

    func testFallsBackToOffsetTimeWhenOriginalMissing() throws {
        let data = try jpeg(exif: [kCGImagePropertyExifOffsetTime: "-03:00"])
        XCTAssertEqual(CaptureOffset.fromImageData(data), -3 * 3600)
    }

    func testReturnsNilWithoutOffsetOrOnGarbage() throws {
        XCTAssertNil(CaptureOffset.fromImageData(try jpeg(exif: nil)))
        XCTAssertNil(CaptureOffset.fromImageData(Data([1, 2, 3, 4])))
    }

    func testWorksOnTruncatedHeaderBytes() throws {
        let data = try jpeg(exif: [kCGImagePropertyExifOffsetTimeOriginal: "+01:00"], side: 600)
        XCTAssertGreaterThan(data.count, 50_000)
        // 只收到開頭一段（真實情況是 PhotoKit 串流的第一塊）也要讀得到。
        XCTAssertEqual(CaptureOffset.fromImageData(data.prefix(4_000)), 3600)
    }
}
