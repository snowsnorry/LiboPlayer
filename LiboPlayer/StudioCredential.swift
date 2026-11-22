import Foundation
import Security

struct StudioProfile: Codable, Equatable {
    let name: String?
    let username: String?

    init(user: [String: Any]) {
        let parts = ["first_name", "last_name"].compactMap { user[$0] as? String }
        let fullName = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        name = fullName.isEmpty ? nil : fullName
        let handle = (user["username"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let bareHandle = handle.drop(while: { $0 == "@" })
        username = bareHandle.isEmpty ? nil : String(bareHandle)
    }
}

struct StudioCredential: Codable, Equatable {
    let token: String
    let signedIn: Bool
    var accountID: String? = nil
    var profile: StudioProfile? = nil

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

    // A deliberate logout must survive relaunch even before a guest token is available.
    static var didSignOut: Bool { UserDefaults.standard.bool(forKey: "studio.didSignOut") }

    static func removeForSignOut() throws {
        let status = SecItemDelete(item as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LibraryError.unavailable }
        UserDefaults.standard.set(true, forKey: "studio.didSignOut")
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
