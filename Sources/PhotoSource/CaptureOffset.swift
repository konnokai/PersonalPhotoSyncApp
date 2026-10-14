import Foundation
import ImageIO

/// 從檔案內容讀出「拍攝當下的 UTC 偏移（秒）」。PHAsset 沒有公開的時區欄位，所以只能讀檔案。
public enum CaptureOffset {
    /// `+09:00`、`-0500`、`+08`、`Z`。
    public static func parse(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s == "Z" || s == "z" { return 0 }
        guard let sign = s.first, sign == "+" || sign == "-" else { return nil }
        let digits = s.dropFirst().filter { $0 != ":" }
        guard digits.allSatisfy(\.isNumber), digits.count == 2 || digits.count == 4,
              let hours = Int(digits.prefix(2)),
              let minutes = digits.count == 4 ? Int(digits.suffix(2)) : 0,
              hours <= 14, minutes < 60 else { return nil }
        let total = hours * 3600 + minutes * 60
        return sign == "-" ? -total : total
    }

    /// 照片：EXIF `OffsetTimeOriginal`，沒有就退到 `OffsetTime`、`OffsetTimeDigitized`。
    /// 只要檔案開頭那一段就夠，所以用增量方式餵資料，截斷的資料也讀得到。
    public static func fromImageData(_ data: Data) -> Int? {
        // 先當成「還沒收完」讀（JPEG 開頭一段就夠）；不行再當成完整檔案讀（完整的 HEIC 要這樣才讀得到）。
        for isFinal in [false, true] {
            let source = CGImageSourceCreateIncremental(nil)
            CGImageSourceUpdateData(source, data as CFData, isFinal)
            if let offset = exifOffset(of: source) { return offset }
        }
        return nil
    }

    private static func exifOffset(of source: CGImageSource) -> Int? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return nil }
        for key in [kCGImagePropertyExifOffsetTimeOriginal, kCGImagePropertyExifOffsetTime,
                    kCGImagePropertyExifOffsetTimeDigitized] {
            if let value = exif[key] as? String, let offset = parse(value) { return offset }
        }
        return nil
    }

    /// 影片：QuickTime `creationdate`，格式像 `2026-10-13T10:00:00+0800`。
    public static func fromQuickTimeDate(_ raw: String) -> Int? {
        guard let t = raw.firstIndex(of: "T") else { return nil }
        let time = raw[raw.index(after: t)...]
        guard let i = time.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) else { return nil }
        return parse(String(time[i...]))
    }
}
