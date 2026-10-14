import Foundation

public enum NameMode: String, Codable, CaseIterable, Sendable {
    case original, timestamp, timestampOriginal, custom

    /// `.custom` 的範本由 `SyncConfig.nameTemplate` 提供。
    public var template: String {
        switch self {
        case .original: return "%OP.%EP"
        case .timestamp: return "%YR-%mR-%dR_%HR-%MR-%SR.%EP"
        case .timestampOriginal: return "%YR-%mR-%dR_%HR-%MR-%SR_%OP.%EP"
        case .custom: return ""
        }
    }
}

public enum ExtensionCase: String, Codable, CaseIterable, Sendable {
    case keep, lower, upper
}

public enum ConflictStrategy: String, Codable, CaseIterable, Sendable {
    /// 同名不同 size 就加 `_1`、`_2`…
    case suffix
    /// 同名一律跳過。
    case skip
    /// 同名不同 size 就覆蓋。
    case overwrite
}

/// 連線設定與同步選項。密碼不在這裡，放 Keychain。
public struct SyncConfig: Codable, Equatable, Sendable {
    public var host = ""
    public var port = 445
    public var share = ""
    public var username = ""
    public var remoteRoot = ""
    /// 被隱藏的相簿：首頁清單變暗，同步時也跳過。
    public var hiddenAlbumIDs: Set<String> = []
    public var nameMode: NameMode = .original
    public var nameTemplate = "%OP.%EP"
    public var subdirectoryTemplate = ""
    public var extensionCase: ExtensionCase = .keep
    public var conflict: ConflictStrategy = .suffix
    public var retries = 2
    public var writeTimestamps = true
    public var requireEncryption = false

    // M4 選配功能，預設關閉。
    public var transcodeVideoToH264 = false
    public var includeLivePhotoVideo = false
    public var backgroundSync = false

    /// 讀不到拍攝時區的項目用這個。第一次啟動時記下當時的裝置時區，之後不再跟著裝置變，
    /// 否則出國一趟，這些項目的檔名會整批改變。
    public var fallbackTimeZoneID = TimeZone.current.identifier

    public init() {}

    /// 「已同步」集合只在這些欄位都沒變時才有效。副檔名大小寫、隱藏相簿、衝突策略不影響上傳到哪、叫什麼，不列入。
    public var destinationFingerprint: String {
        let root = remoteRoot.split(separator: "/").joined(separator: "/")
        return [host.lowercased(), share.lowercased(), root, effectiveNameTemplate, subdirectoryTemplate,
                String(transcodeVideoToH264), String(includeLivePhotoVideo),
                fallbackTimeZoneID].joined(separator: "\n")
    }

    /// 檔名或子目錄有用到日期時間才需要知道拍攝時區。
    public var usesDateTokens: Bool {
        let tokens = ["%YR", "%yR", "%mR", "%dR", "%HR", "%MR", "%SR"]
        return tokens.contains { effectiveNameTemplate.contains($0) || subdirectoryTemplate.contains($0) }
    }

    /// 檔名或子目錄有用到相簿名稱才需要去列舉相簿。
    public var usesAlbumToken: Bool {
        effectiveNameTemplate.contains("%AP") || subdirectoryTemplate.contains("%AP")
    }

    public var fallbackTimeZone: TimeZone { TimeZone(identifier: fallbackTimeZoneID) ?? .current }

    /// 連線一定要有的欄位；缺的話不必真的去連，直接告訴使用者填什麼。
    public var missingConnectionFields: [String] {
        [("主機", host), ("共享名稱", share), ("帳號", username)]
            .filter { $0.1.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(\.0)
    }

    public var effectiveNameTemplate: String {
        nameMode == .custom ? nameTemplate : nameMode.template
    }
}
