import CryptoKit
import Foundation
import Observation

/// The index and its audio files belong to one studio account (or to the guest).
@MainActor @Observable
final class EpisodeCollection {
    private struct Bookmark: Codable {
        let episode: Episode
    }

    private struct Download: Codable {
        let episode: Episode
        let filename: String
    }

    private struct Index: Codable {
        var bookmarks: [String: Bookmark] = [:]
        var downloads: [String: Download] = [:]
        var shows: [String: Show] = [:]
    }

    private let directory: URL
    private var index = Index()
    private let files = FileManager.default
    private(set) var downloading = Set<String>()
    private(set) var loadError: Error?

    init(account: String?, root: URL = .applicationSupportDirectory) {
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
        next.bookmarks[episode.id] = saved ? Bookmark(episode: episode.offlineMetadata) : nil
        if let show { next.shows[show.id] = show }
        try commit(next)
    }

    func beginDownload(_ id: String) -> Bool { localURL(id) == nil && downloading.insert(id).inserted }
    func endDownload(_ id: String) { downloading.remove(id) }

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
