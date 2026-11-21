import CryptoKit
import Foundation

/// Evictable browsing metadata. The account's downloads and bookmarks live in Application Support.
struct WatchCatalogCache {
    private let directory: URL

    init(account: String?) {
        let owner = account.map { "account-" + Self.key($0) } ?? "guest"
        directory = URL.cachesDirectory.appending(path: "StudioCatalog").appending(component: owner)
    }

    private static func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appending(component: Self.key(key))) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func store<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(component: Self.key(key)), options: .atomic)
    }
}
