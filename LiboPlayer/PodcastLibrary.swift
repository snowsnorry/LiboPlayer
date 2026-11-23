import Foundation
import Observation

@Observable @MainActor
final class PodcastLibrary {
    private(set) var shows: [Show] = []
    private var currentCredential: StudioCredential?
    var account: String? { currentCredential?.accountID }
    var isSignedIn: Bool { currentCredential?.signedIn == true }
    var profile: StudioProfile? { currentCredential?.profile }
    private(set) var subscriptions: [String: String] = [:]
    private(set) var episodes: [String: [Episode]] = [:]
    private(set) var feed: [Episode] = []
    private var serverPlayed: Set<String>?
    private(set) var updatingPlayed = Set<String>()
    @ObservationIgnored var companionStateChanged: (() -> Void)?
    private var identityGeneration = UUID()
    private var catalogLoad: Task<StudioSession, Error>?
    var busy: Bool { catalogLoad != nil }
    private(set) var ready = false
    private(set) var changing = Set<String>()
    var message: String?
    private(set) var session = StudioSession()
    @ObservationIgnored private var pending: [String: Task<[Episode], Error>] = [:]

    private(set) var collection: EpisodeCollection

    init() {
        let saved = try? StudioCredential.saved()
        currentCredential = saved
        let owner = saved?.accountID
        collection = EpisodeCollection(account: owner)
        serverPlayed = Self.cachedPlayed(for: owner)
        if let error = collection.loadError { message = error.localizedDescription }
        #if os(watchOS)
        restoreWatchCatalog()
        #endif
    }

    var followedShows: [Show] { shows.filter { subscriptions[$0.id] != nil } }
    #if os(watchOS)
    private var cachedArchives = Set<String>()
    private var watchCache: WatchCatalogCache { WatchCatalogCache(account: account) }

    // Never treat cached metadata as a validated studio session or a credential.
    @discardableResult
    func restoreWatchCatalog() -> Bool {
        guard let cached = watchCache.read(Catalog.self, key: "catalog"), cached.account == account else { return false }
        if !ready {
            shows = cached.shows
            subscriptions = cached.subscriptions
            if serverPlayed == nil { serverPlayed = Set(cached.played) }
        }
        return true
    }

    func restoreWatchArchives(_ shows: [Show]) -> Bool {
        var restored = false
        for show in shows where episodes[show.id] == nil {
            if let rows = watchCache.read([Episode].self, key: "show." + show.id) {
                episodes[show.id] = rows
                cachedArchives.insert(show.id)
                restored = true
            }
        }
        if restored { rebuildFeed() }
        return shows.isEmpty || shows.contains { episodes[$0.id] != nil }
    }

    #endif

    func show(for episode: Episode) -> Show? {
        shows.first { $0.id == episode.showID } ?? collection.cachedShow(episode.showID)
    }

    func setSaved(_ saved: Bool, for episode: Episode) {
        do {
            try collection.setSaved(saved, episode: episode, show: show(for: episode))
            companionStateChanged?()
        } catch { message = error.localizedDescription }
    }

    func toggleDownload(_ episode: Episode) async {
        let shelf = collection
        do {
            if shelf.localURL(episode.id) != nil {
                try shelf.removeDownload(episode.id)
                return
            }
            try await download(episode, to: shelf)
        } catch {
            if shelf === collection { message = (error as? LibraryError)?.errorDescription ?? String(localized: "Couldn’t update the download. Try again.") }
        }
    }

    func download(_ episode: Episode, to shelf: EpisodeCollection) async throws {
        guard collection === shelf else { throw CancellationError() }
        guard !episode.locked else { throw LibraryError.locked }
        guard let download = shelf.beginDownload(episode.id) else { return }
        defer { shelf.endDownload(episode.id) }
        let source = try await sessionForRequest()
        guard shelf === collection else { throw CancellationError() }
        let url = try await source.stream(for: episode)
        let audioFile = try await EpisodeAudio.download(from: url) { fraction in
            download.update(fraction)
        }
        defer { try? FileManager.default.removeItem(at: audioFile) }
        guard shelf === collection else { throw CancellationError() }
        try Task.checkCancellation()
        let current = session.withCurrentAccess(episode)
        guard !current.locked else { throw LibraryError.locked }
        try shelf.install(audioFile, episode: current, show: show(for: episode), extension: audioFile.pathExtension)
    }

    func refresh(quietIfCached: Bool = false) async {
        guard !busy, changing.isEmpty, updatingPlayed.isEmpty else { return }
        let generation = identityGeneration
        do { _ = try await reloadCatalog() }
        catch {
            guard generation == identityGeneration else { return }
            let hasOfflineContent = !collection.saved.isEmpty || !collection.downloaded.isEmpty
            if !Task.isCancelled && !(quietIfCached && (ready || hasOfflineContent)) { message = LibraryError.message(for: error) }
        }
    }

    func sessionForRequest() async throws -> StudioSession {
        try Task.checkCancellation()
        if session.isAvailable { return session }
        return try await reloadCatalog()
    }

    func useCredential(_ credential: StudioCredential) async throws {
        // A previous account's catalog must finish before the new identity can be installed.
        let generation = identityGeneration
        while let catalogLoad {
            _ = await catalogLoad.result
            guard generation == identityGeneration else { throw CancellationError() }
        }
        _ = try await reloadCatalog(using: credential)
    }

    func signOut() throws {
        try StudioCredential.removeForSignOut()
        resetIdentity(to: nil)
        companionStateChanged?()
    }

    #if os(watchOS)
    // Install the phone's validated identity locally even when the studio is temporarily offline.
    func adoptPhoneCredential(_ credential: StudioCredential) throws {
        let saved = try StudioCredential.saved()
        guard saved != credential, credential.signedIn || saved?.signedIn == true else { return }
        try credential.save()
        resetIdentity(to: credential)
    }
    #endif

    private func resetIdentity(to credential: StudioCredential?) {
        identityGeneration = UUID()
        catalogLoad?.cancel()
        catalogLoad = nil
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        session = StudioSession()
        if account != credential?.accountID {
            collection = EpisodeCollection(account: credential?.accountID)
        }
        currentCredential = credential
        message = nil
        changing.removeAll()
        updatingPlayed.removeAll()
        episodes.removeAll()
        feed = []
        subscriptions.removeAll()
        serverPlayed = Self.cachedPlayed(for: account)
        // On iPhone the shows come from the public home page.
        // Keep them visible while a guest session is being established.
        #if os(watchOS)
        shows = []
        ready = false
        cachedArchives.removeAll()
        restoreWatchCatalog()
        #endif
    }

    private func reloadCatalog(using selected: StudioCredential? = nil) async throws -> StudioSession {
        if let catalogLoad { return try await catalogLoad.value }
        let generation = identityGeneration
        let load = Task {
            defer { if generation == identityGeneration { catalogLoad = nil } }
            let candidate = StudioSession()
            let saved = try StudioCredential.saved()
            let catalog = try await candidate.catalog(using: selected ?? saved)
            try Task.checkCancellation()
            guard generation == identityGeneration else { throw CancellationError() }
            if let credential = candidate.credential, credential != saved { try credential.save() }
            for task in pending.values { task.cancel() }
            pending.removeAll()
            session = candidate
            episodes.removeAll()
            shows = catalog.shows
            if account != catalog.account {
                collection = EpisodeCollection(account: catalog.account)
                serverPlayed = Self.cachedPlayed(for: catalog.account)
            }
            currentCredential = candidate.credential
            do { try collection.updateAccess(candidate.withCurrentAccess) }
            catch { message = error.localizedDescription }
            #if os(watchOS)
            cachedArchives.removeAll()
            watchCache.store(catalog, key: "catalog")
            #endif
            subscriptions = catalog.subscriptions
            storePlayed(Set(catalog.played))
            ready = true
            rebuildFeed()
            companionStateChanged?()
            return candidate
        }
        catalogLoad = load
        return try await load.value
    }

    func load(_ show: Show) async throws {
        #if os(watchOS)
        if !cachedArchives.contains(show.id), episodes[show.id] != nil { return }
        #else
        guard episodes[show.id] == nil else { return }
        #endif
        let source = try await sessionForRequest()
        try Task.checkCancellation()
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
            #if os(watchOS)
            cachedArchives.remove(show.id)
            watchCache.store(rows.map(\.offlineMetadata), key: "show." + show.id)
            #endif
            pending[show.id] = nil
            rebuildFeed()
        } catch {
            if source === session { pending[show.id] = nil }
            throw error
        }
    }

    func loadArchive() async throws {
        #if os(watchOS)
        let source = session
        let missing = followedShows.filter { episodes[$0.id] == nil || cachedArchives.contains($0.id) }
            .sorted { ($0.lastEpisode ?? 0) > ($1.lastEpisode ?? 0) }
        var shows = missing.makeIterator()
        var firstError: Error?
        try await withThrowingTaskGroup(of: Error?.self) { group in
            func enqueue(_ show: Show) {
                group.addTask { @MainActor in
                    try Task.checkCancellation()
                    guard self.session === source else { throw CancellationError() }
                    do { try await self.load(show); return nil }
                    catch is CancellationError { throw CancellationError() }
                    catch { return error }
                }
            }
            for _ in 0..<3 {
                if let show = shows.next() { enqueue(show) }
            }
            while let result = try await group.next() {
                try Task.checkCancellation()
                if firstError == nil { firstError = result }
                if let show = shows.next() { enqueue(show) }
            }
        }
        if let firstError { throw firstError }
        #else
        for show in shows where subscriptions[show.id] != nil {
            try Task.checkCancellation()
            try await load(show)
        }
        #endif
    }

    var archiveReady: Bool {
        shows.allSatisfy { subscriptions[$0.id] == nil || episodes[$0.id] != nil }
    }

    private static func cachedPlayed(for owner: String?) -> Set<String>? {
        guard let owner, let ids = UserDefaults.standard.stringArray(forKey: "studio.played." + owner) else { return nil }
        return Set(ids)
    }

    private func storePlayed(_ ids: Set<String>) {
        guard serverPlayed != ids else { return }
        serverPlayed = ids
        if let account { UserDefaults.standard.set(Array(ids), forKey: "studio.played." + account) }
    }

    func wasPlayed(_ episode: Episode) -> Bool {
        guard account != nil else { return episode.played }
        return serverPlayed?.contains(episode.id) ?? episode.played
    }

    func refreshPlayed(for owner: String) async throws -> StudioSession {
        let source = try await sessionForRequest()
        guard source.credential?.accountID == owner, account == owner else { throw CancellationError() }
        let ids = try await source.playedIDs()
        try Task.checkCancellation()
        guard source === session else { throw CancellationError() }
        storePlayed(ids)
        return source
    }

    func updatePlayed(_ played: Bool, id: String, using source: StudioSession) async throws {
        try Task.checkCancellation()
        guard source === session, var ids = serverPlayed else { throw CancellationError() }
        guard ids.contains(id) != played else { return }
        updatingPlayed.insert(id)
        let generation = identityGeneration
        defer { if generation == identityGeneration { updatingPlayed.remove(id) } }
        try await source.setPlayed(played, id: id)
        guard source === session else { throw CancellationError() }
        if played { ids.insert(id) } else { ids.remove(id) }
        storePlayed(ids)
    }

    func toggle(_ show: Show) async {
        guard account != nil, changing.isEmpty, !busy else { return }
        changing.insert(show.id)
        let generation = identityGeneration
        defer { if generation == identityGeneration { changing.remove(show.id) } }
        let owner = account
        do {
            let source = try await sessionForRequest()
            guard account == owner else { throw LibraryError.expired }
            let old = subscriptions[show.id]
            let updated = try await source.setFollow(old == nil, show: show)
            guard source === session else { return }
            subscriptions = updated
            rebuildFeed()
        } catch {
            if generation == identityGeneration { message = String(localized: "Couldn’t update your followed shows. Refresh the catalog and try again.") }
        }
    }

    private func rebuildFeed() {
        var ids = Set<String>()
        feed = episodes.filter { subscriptions[$0.key] != nil }
            .flatMap(\.value).filter { ids.insert($0.id).inserted }.sorted(by: Episode.precedes)
    }
}
