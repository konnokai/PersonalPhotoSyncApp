import Foundation
import Security

enum Keychain {
    private static let service = "com.konnokai.PhotoSync.nas"

    /// 沒有這個項目算空密碼，不算錯誤；其他狀態碼要讓呼叫端看得到。
    static func load(account: String) -> (password: String, status: OSStatus) {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return ("", errSecSuccess) }
        guard status == errSecSuccess, let data = item as? Data else { return ("", status) }
        return (String(data: data, encoding: .utf8) ?? "", errSecSuccess)
    }

    /// 空密碼就刪除項目。更新失敗時舊值還在，不會像先刪再寫那樣在寫入失敗時連舊的也丟掉。
    @discardableResult
    static func save(_ password: String, account: String) -> OSStatus {
        guard !password.isEmpty else {
            let status = SecItemDelete(base(account) as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
        let data = Data(password.utf8)
        let status = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var query = base(account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }

    static func message(for status: OSStatus) -> String {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? ""
        return "Keychain 錯誤 \(status)：\(text)"
    }

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
