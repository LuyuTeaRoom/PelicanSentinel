import Foundation
import Security
import CryptoKit
import PelicanCore

struct KeychainStore {
    var service = "com.pelicansentinel.openai"
    static func forProvider(_ provider: ProviderID, configuration: ProviderConfiguration) throws -> KeychainStore {
        var service = "com.pelicansentinel.\(provider.rawValue)"
        if provider == .compatible {
            let endpoint = try CompatibleEndpoint.normalizedBaseURL(configuration.baseURL)
            let scope = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
            service += ".\(scope)"
        }
        return KeychainStore(service: service)
    }
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key"] }
    func read() throws -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw keyError(status) }
        return String(data: data, encoding: .utf8)
    }
    func save(_ value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(q as CFDictionary, nil)
            if added != errSecSuccess { throw keyError(added) }
        } else if status != errSecSuccess { throw keyError(status) }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { throw keyError(status) }
    }
    private func keyError(_ status: OSStatus) -> NSError { NSError(domain: "Keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not access Keychain (\(status))."]) }
}
