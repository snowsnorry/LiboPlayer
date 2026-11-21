import CryptoKit
import Foundation
import Observation

@MainActor @Observable
final class EpisodeDownload {
    private(set) var fractionCompleted: Double?

    func update(_ fraction: Double) {
        fractionCompleted = max(fractionCompleted ?? 0, min(fraction, 1))
    }
}

/// The index and its audio files belong to one studio account (or to the guest).
@MainActor @Observable
final class EpisodeCollection {
    struct BookmarkVersion: Codable, Comparable {
        let modified: Double
        let revision: String

        static let legacy = Self(modified: 0, revision: "")

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.modified, lhs.revision) < (rhs.modified, rhs.revision)
        }
    }

    struct BookmarkChange: Codable {
        let episode: Episode?
        let version: BookmarkVersion
    }

    struct BookmarkSnapshot: Codable {
        let account: String?
        let changes: [String: BookmarkChange]
        let shows: [String: Show]
    }

    private struct Bookmark: Codable {
        let episode: Episode
    }

    private struct Download: Codable {
        let episode: Episode
        let filename: String
    }

    private struct Index: Codable {
        var bookmarks: [String: Bookmark] = [:]
        // Missing on indexes written before paired bookmark sync.
        var bookmarkVersions: [String: BookmarkVersion]?
        var downloads: [String: Download] = [:]
        var shows: [String: Show] = [:]
    }

    let account: String?
    private let directory: URL
    private var index = Index()
    private let files = FileManager.default
    private(set) var downloadsInProgress: [String: EpisodeDownload] = [:]
    private(set) var loadError: Error?

    init(account: String?, root: URL = .applicationSupportDirectory) {
        self.account = account
        let owner = account.map { "account-" + SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() } ?? "guest"
        directory = root.appending(path: "EpisodeCollections").appending(component: owner)
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(component: "index.json")
            if files.fileExists(atPath: url.path) {
                index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: url))
            }
            let existing = index.downloads.filter { files.fileExists(atPath: directory.appending(component: $0.value.filename).path) }
            if existing.count != index.downloads.count {
                var repaired = index
                repaired.downloads = existing
                try commit(repaired)
            }
            // A termination between a file move and the atomic index write can leave an orphan.
            let referenced = Set(existing.values.map(\.filename))
            for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where url.lastPathComponent.hasPrefix("audio-") && !referenced.contains(url.lastPathComponent) {
                try files.removeItem(at: url)
            }
        } catch { loadError = error }
    }

    var saved: [Episode] { index.bookmarks.values.map(\.episode).sorted(by: Episode.precedes) }
    var downloaded: [Episode] { index.downloads.values.map(\.episode).sorted(by: Episode.precedes) }
    func isSaved(_ id: String) -> Bool { index.bookmarks[id] != nil }
    func cachedShow(_ id: String) -> Show? { index.shows[id] }
    func localURL(_ id: String) -> URL? {
        guard let file = index.downloads[id]?.filename else { return nil }
        return directory.appending(component: file)
    }

    func updateAccess(_ currentAccess: (Episode) -> Episode) throws {
        var next = index
        var changed = false
        for (id, bookmark) in index.bookmarks {
            let episode = currentAccess(bookmark.episode)
            if episode.locked != bookmark.episode.locked {
                next.bookmarks[id] = Bookmark(episode: episode)
                changed = true
            }
        }
        for (id, download) in index.downloads {
            let episode = currentAccess(download.episode)
            if episode.locked != download.episode.locked {
                next.downloads[id] = Download(episode: episode, filename: download.filename)
                changed = true
            }
        }
        if changed { try commit(next) }
    }

    func setSaved(_ saved: Bool, episode: Episode, show: Show?) throws {
        var next = index
        let previous = index.bookmarkVersions?[episode.id]?.modified ?? 0
        let version = BookmarkVersion(modified: max(Date().timeIntervalSince1970, previous.nextUp),
                                      revision: UUID().uuidString)
        if next.bookmarkVersions == nil { next.bookmarkVersions = [:] }
        next.bookmarkVersions?[episode.id] = version
        next.bookmarks[episode.id] = saved ? Bookmark(episode: episode.offlineMetadata) : nil
        if let show { next.shows[show.id] = show }
        try commit(next)
    }

    func bookmarkSnapshot() -> BookmarkSnapshot {
        let ids = Set(index.bookmarkVersions?.keys.map { $0 } ?? []).union(index.bookmarks.keys)
        let changes = Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, BookmarkChange(episode: index.bookmarks[id]?.episode, version: index.bookmarkVersions?[id] ?? .legacy))
        })
        let showIDs = Set(index.bookmarks.values.map { $0.episode.showID })
        return BookmarkSnapshot(account: account, changes: changes, shows: index.shows.filter { showIDs.contains($0.key) })
    }

    func mergeBookmarks(_ snapshot: BookmarkSnapshot, access: (Episode) -> Episode) throws {
        guard account == snapshot.account else { return }
        var next = index
        var changed = false
        for (id, incoming) in snapshot.changes {
            let old = index.bookmarkVersions?[id] ?? (index.bookmarks[id] != nil ? .legacy : nil)
            if let old, old >= incoming.version { continue }
            if next.bookmarkVersions == nil { next.bookmarkVersions = [:] }
            next.bookmarkVersions?[id] = incoming.version
            next.bookmarks[id] = incoming.episode.map { Bookmark(episode: access($0.offlineMetadata)) }
            if let episode = incoming.episode, let show = snapshot.shows[episode.showID] { next.shows[show.id] = show }
            changed = true
        }
        if changed { try commit(next) }
    }

    func beginDownload(_ id: String) -> EpisodeDownload? {
        guard localURL(id) == nil, downloadsInProgress[id] == nil else { return nil }
        let download = EpisodeDownload()
        downloadsInProgress[id] = download
        return download
    }

    func endDownload(_ id: String) { downloadsInProgress[id] = nil }

    func install(_ temporary: URL, episode: Episode, show: Show?, extension ext: String) throws {
        guard localURL(episode.id) == nil else { return }
        let name = "audio-" + UUID().uuidString + "." + ext
        var file = directory.appending(component: name)
        try files.moveItem(at: temporary, to: file)
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try file.setResourceValues(values)
            var next = index
            next.downloads[episode.id] = Download(episode: episode.offlineMetadata, filename: name)
            if let show { next.shows[show.id] = show }
            try commit(next)
        } catch {
            try? files.removeItem(at: file)
            throw error
        }
    }

    func removeDownload(_ id: String) throws {
        guard let file = localURL(id) else { return }
        var next = index
        next.downloads[id] = nil
        // Commit first: an interrupted removal is cleaned up on the next launch.
        try commit(next)
        if files.fileExists(atPath: file.path) { try files.removeItem(at: file) }
    }

    private func commit(_ proposed: Index) throws {
        if let loadError { throw loadError }
        var next = proposed
        let referenced = Set(next.bookmarks.values.map { $0.episode.showID } + next.downloads.values.map { $0.episode.showID })
        next.shows = next.shows.filter { referenced.contains($0.key) }
        try JSONEncoder().encode(next).write(to: directory.appending(component: "index.json"), options: .atomic)
        index = next
    }
}
