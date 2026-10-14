import Foundation

/// 設定頁的子目錄預設。只收能穩定表達的項目：傳檔日期每天不同，同一張照片會每天換資料夾，所以不收。
public enum SubdirectoryPreset: CaseIterable, Sendable {
    case none, year, yearMonth, yearThenYearMonth, yearMonthDay, yearThenMonthThenDay
    case album, deviceThenAlbum, device, deviceThenYearMonth, extensionName

    public var template: String {
        switch self {
        case .none: return ""
        case .year: return "%YR"
        case .yearMonth: return "%YR/%mR"
        case .yearThenYearMonth: return "%YR/%YR-%mR"
        case .yearMonthDay: return "%YR-%mR-%dR"
        case .yearThenMonthThenDay: return "%YR/%mR/%dR"
        case .album: return "%AP"
        case .deviceThenAlbum: return "%DP/%AP"
        case .device: return "%DP"
        case .deviceThenYearMonth: return "%DP/%YR-%mR"
        case .extensionName: return "%EP"
        }
    }

    public var title: String {
        switch self {
        case .none: return "不分資料夾"
        case .year: return "年"
        case .yearMonth: return "年／月"
        case .yearThenYearMonth: return "年／年-月"
        case .yearMonthDay: return "年-月-日"
        case .yearThenMonthThenDay: return "年／月／日"
        case .album: return "相簿名稱"
        case .deviceThenAlbum: return "裝置名稱／相簿名稱"
        case .device: return "裝置名稱"
        case .deviceThenYearMonth: return "裝置名稱／年-月"
        case .extensionName: return "副檔名"
        }
    }

    public init?(template: String) {
        guard let match = Self.allCases.first(where: { $0.template == template }) else { return nil }
        self = match
    }

    public var sample: String { Self.preview(template: template) }

    /// 用固定的範例資料走一次真正的範本引擎，畫面上的範例才不會和實際結果脫節。
    public static func preview(template: String) -> String {
        let context = NameContext(
            originalName: "IMG_0001", assetID: "SAMPLE", creationDate: Date(timeIntervalSince1970: 1_773_065_142),
            albumName: "QQ", deviceName: "iPhone", sequence: 1, outputExtension: "HEIC")
        let path = NameTemplate.render(template, context: context, timeZone: TimeZone(identifier: "UTC")!,
                                       extensionCase: .keep)
        return path.isEmpty ? "（直接放在根目錄）" : path
    }
}
