//
//  KeychainStore.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  Minimal Keychain wrapper for secrets (API keys, tokens). Backed by
//  `SecItem*` Security framework calls — no third-party dependency.
//  Instances are configured with a service identifier + account name;
//  the static `.openAIAPIKey` convenience covers the only secret we
//  store today, and the shape generalizes when we add multi-provider
//  support.
//

import Foundation
import Security

struct KeychainStore {
    let service: String
    let account: String

    func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    func write(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

extension KeychainStore {
    private static let defaultService = Bundle.main.bundleIdentifier ?? "com.zerro.app"

    /// The single API-key slot we store today. When multi-provider support
    /// lands, swap callers to a parameterized factory.
    static let openAIAPIKey = KeychainStore(service: defaultService, account: "openai_api_key")
}
