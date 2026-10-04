import Foundation
import Security

/// MiMo Token Plan 凭据：小米账号网页会话 Cookie。
/// 额度只在小米开放平台控制台，tp-* 推理 Key 查不到额度，
/// 必须由用户在浏览器登录 platform.xiaomimimo.com 后手动粘贴 Cookie。
/// Cookie 存 Keychain，过期后重新粘贴。
struct MimoAuthSession: Sendable, Equatable {
    enum Source: String, Sendable, Equatable {
        case manualCookie = "cookie"

        var displayName: String {
            switch self {
            case .manualCookie: return "手动 Cookie"
            }
        }
    }

    var cookie: String
    var planName: String?
    var source: Source

    var accountKey: String {
        if let planName, !planName.isEmpty { return "plan:\(planName)" }
        return "cookie:\(cookie.prefix(8))...\(cookie.suffix(6))"
    }
}

enum MimoAuth {
    private static let keychainService = "com.nanvon.ccbar.mimo"
    private static let keychainAccount = "primary"

    static func load() -> MimoAuthSession? {
        guard let raw = loadFromKeychain(), let cookie = sanitizeCookie(raw) else { return nil }
        return MimoAuthSession(cookie: cookie, planName: nil, source: .manualCookie)
    }

    // MARK: - Keychain 存取

    static func loadFromKeychain() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func saveToKeychain(cookie: String) -> Bool {
        guard let cleaned = sanitizeCookie(cookie),
              let data = cleaned.data(using: .utf8) else { return false }
        deleteFromKeychain()
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func deleteFromKeychain() -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Cookie 清洗

    /// Cookie 是可打印 ASCII 的 `k=v; k=v` 串；小米额度接口要求其中含 serviceToken。
    /// 不能沿用 API Key 的校验思路，Cookie 合法字符包含 `=`、`;` 与空格。
    static func sanitizeCookie(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E }) else {
            return nil
        }
        return trimmed
    }

    static func looksLikeSessionCookie(_ cookie: String) -> Bool {
        cookie.contains("serviceToken=")
    }
}
