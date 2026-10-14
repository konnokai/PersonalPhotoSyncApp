import Foundation

/// 一張照片只放進一個相簿資料夾。照片同時在多個相簿時，結果要在每次同步都一樣，否則同一張照片會被傳到不同資料夾。
public enum AlbumAssignment {
    /// 寫死而不是取系統「最近項目」的在地化名稱：換系統語言不能讓整批照片換資料夾。
    public static let fallbackName = "最近項目"

    public struct Album: Sendable {
        public var id: String
        public var name: String
        public var assetIDs: [String]

        public init(id: String, name: String, assetIDs: [String]) {
            self.id = id
            self.name = name
            self.assetIDs = assetIDs
        }
    }

    /// 名稱排序最前的相簿勝出，名稱相同再比 ID；不依賴 PhotoKit 回傳的順序。
    public static func assign(_ albums: [Album]) -> [String: String] {
        var result: [String: String] = [:]
        for album in albums.sorted(by: { ($0.name, $0.id) < ($1.name, $1.id) }) {
            for id in album.assetIDs where result[id] == nil { result[id] = album.name }
        }
        return result
    }

    public static func name(for assetID: String, in assignment: [String: String]) -> String {
        assignment[assetID] ?? fallbackName
    }
}
