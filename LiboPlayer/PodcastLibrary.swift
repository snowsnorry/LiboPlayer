import Foundation
import Observation

@Observable @MainActor
final class PodcastLibrary {
    private(set) var shows: [Show] = []
    private(set) var account: String?
    private(set) var subscriptions: [String: String] = [:]
    private(set) var episodes: [String: [Episode]] = [:]
    private(set) var feed: [Episode] = []
    private var serverPlayed = Set<String>()
    private var playedChanges: [String: Bool] = [:]
    private(set) var updatingPlayed = Set<String>()
    private(set) var busy = false
    private(set) var ready = false
    private(set) var changing = Set<String>()
    var message: String?
    private(set) var session = StudioSession()
    @ObservationIgnored private var pending: [String: Task<[Episode], Error>] = [:]

    func refresh() async {
        guard !busy, changing.isEmpty, updatingPlayed.isEmpty else { return }
        busy = true
        defer { busy = false }
        let candidate = StudioSession()
        do {
            let catalog = try await candidate.catalog()
            for task in pending.values { task.cancel() }
            pending.removeAll()
            session = candidate
            episodes.removeAll()
            shows = catalog.shows
            account = catalog.account
            subscriptions = catalog.subscriptions
            serverPlayed = Set(catalog.played)
            playedChanges.removeAll()
            ready = true
            rebuildFeed()
        } catch { if !Task.isCancelled { message = LibraryError.unavailable.errorDescription } }
    }

    func load(_ show: Show) async throws {
        guard episodes[show.id] == nil else { return }
        let source = session
        let task: Task<[Episode], Error>
        if let existing = pending[show.id] { task = existing }
        else {
            task = Task { try await source.episodes(for: show).sorted(by: Episode.precedes) }
            pending[show.id] = task
        }
        do {
            let rows = try await task.value
            guard source === session else { return }
            episodes[show.id] = rows
            pending[show.id] = nil
            rebuildFeed()
        } catch {
            if source === session { pending[show.id] = nil }
            throw error
        }
    }

    func loadArchive() async throws {
        for show in shows where subscriptions[show.id] != nil {
            try Task.checkCancellation()
            try await load(show)
        }
    }

    var archiveReady: Bool {
        shows.allSatisfy { subscriptions[$0.id] == nil || episodes[$0.id] != nil }
    }

    func wasPlayed(_ episode: Episode) -> Bool {
        playedChanges[episode.id] ?? (serverPlayed.contains(episode.id) || episode.played)
    }

    func updatePlayed(_ played: Bool, for episode: Episode) async throws {
        guard account != nil, !busy, updatingPlayed.insert(episode.id).inserted else {
            throw CancellationError()
        }
        defer { updatingPlayed.remove(episode.id) }
        try await session.setPlayed(played, id: episode.id)
        playedChanges[episode.id] = played
    }

    func toggle(_ show: Show) async {
        guard account != nil, changing.isEmpty, !busy else { return }
        changing.insert(show.id)
        defer { changing.remove(show.id) }
        let source = session
        let old = subscriptions[show.id]
        do {
            let updated = try await source.setFollow(old == nil, show: show)
            guard source === session else { return }
            subscriptions = updated
            rebuildFeed()
        } catch { message = String(localized: "Couldn’t update your followed shows. Refresh the catalog and try again.") }
    }

    private func rebuildFeed() {
        var ids = Set<String>()
        feed = episodes.filter { subscriptions[$0.key] != nil }
            .flatMap(\.value).filter { ids.insert($0.id).inserted }.sorted(by: Episode.precedes)
    }
}
