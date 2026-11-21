import Foundation
import Security

struct StudioCredential: Codable, Equatable {
    let token: String
    let signedIn: Bool

    private static let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "app.liboplayer.ios.studio",
        kSecAttrAccount as String: "play.libolibo.me"
    ]

    static func saved() throws -> Self? {
        var query = item
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw LibraryError.unavailable }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func save() throws {
        let fields: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(self),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(Self.item as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound {
            let newItem = Self.item.merging(fields) { _, new in new }
            status = SecItemAdd(newItem as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw LibraryError.unavailable }
    }
}
