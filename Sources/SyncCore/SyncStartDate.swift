import Foundation

public enum SyncStartDate {
    /// 沒有拍攝時間的項目一律納入：上傳多一份比永遠被略過安全。
    public static func includes(creationDate: Date?, since: Date?) -> Bool {
        guard let since, let creationDate else { return true }
        return creationDate >= since
    }
}
