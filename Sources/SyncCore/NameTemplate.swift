import Foundation

public struct NameContext: Sendable {
    public var originalName: String      // 不含副檔名
    public var assetID: String
    public var creationDate: Date?
    public var albumName: String
    public var deviceName: String
    public var sequence: Int
    public var outputExtension: String

    public init(originalName: String, assetID: String, creationDate: Date?, albumName: String,
                deviceName: String, sequence: Int, outputExtension: String) {
        self.originalName = originalName
        self.assetID = assetID
        self.creationDate = creationDate
        self.albumName = albumName
        self.deviceName = deviceName
        self.sequence = sequence
        self.outputExtension = outputExtension
    }
}

public enum NameTemplate {
    private static let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)

    public static func sanitize(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { illegal.contains($0) ? "_" : $0 }))
    }

    /// 回傳相對路徑；範本裡的 `/` 保留成目錄分隔，token 值裡的 `/` 會被換掉。
    public static func render(_ template: String, context: NameContext, timeZone: TimeZone,
                              extensionCase: ExtensionCase) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = context.creationDate.map {
            calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0)
        }
        func two(_ v: Int?) -> String { v.map { String(format: "%02d", $0) } ?? "00" }

        var ext = context.outputExtension
        switch extensionCase {
        case .keep: break
        case .lower: ext = ext.lowercased()
        case .upper: ext = ext.uppercased()
        }

        let values: [String: String] = [
            "YR": parts?.year.map { String(format: "%04d", $0) } ?? "0000",
            "yR": parts?.year.map { String(format: "%02d", $0 % 100) } ?? "00",
            "mR": two(parts?.month), "dR": two(parts?.day),
            "HR": two(parts?.hour), "MR": two(parts?.minute), "SR": two(parts?.second),
            "OP": context.originalName,
            "ID": String(context.assetID.split(separator: "/").first ?? ""),
            "AP": context.albumName,
            "DP": context.deviceName,
            "EP": ext,
            "IP": String(context.sequence),
        ]

        var out = ""
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            if chars[i] == "%", i + 2 < chars.count, let v = values[String(chars[i + 1...i + 2])] {
                out += sanitize(v)
                i += 3
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        if ext.isEmpty, out.hasSuffix(".") { out.removeLast() }
        return out.split(separator: "/").map { sanitize(String($0)) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }
}
