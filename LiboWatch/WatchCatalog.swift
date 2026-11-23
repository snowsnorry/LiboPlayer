import SwiftUI

struct WatchCatalog: View {
    let route: WatchRoute
    @Environment(PodcastLibrary.self) private var library
    @State private var error: String?
    @State private var loading = true
    @State private var attempt = 0
    @State private var showingCache = false

    private var title: String {
        switch route {
        case .allShows: String(localized: "All Shows")
        case .following: String(localized: "Following")
        case .latest: String(localized: "Latest Episodes")
        case .show: ""
        default: ""
        }
    }

    var body: some View {
        List {
            if showingCache {
                Button("Offline · Try Again", systemImage: "wifi.slash") { attempt += 1 }.font(.caption)
            }
            if case .show(let show) = route {
                HStack {
                    WatchArt(address: show.artwork, size: 35)
                    Text(show.name).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                    let follows = library.subscriptions[show.id] != nil
                    if library.account == nil {
                        NavigationLink(value: WatchRoute.account) {
                            Image(systemName: "heart").frame(minWidth: 36, minHeight: 40)
                        }.accessibilityLabel("Sign in to follow show")
                    } else {
                        Button { Task { await library.toggle(show) } } label: {
                            Image(systemName: follows ? "heart.fill" : "heart").frame(minWidth: 36, minHeight: 40)
                        }
                        .disabled(!library.changing.isEmpty)
                        .accessibilityLabel(follows ? Text("Unfollow Show") : Text("Follow Show"))
                    }
                }.listRowBackground(Color.clear)
            }
            let hasLatest = route == .latest && !library.feed.isEmpty
            if hasLatest { rows }
            if let error {
                Text(error)
                Button("Try Again") { attempt += 1 }
                NavigationLink("Open Downloaded", value: WatchRoute.downloaded)
                if error == LibraryError.expired.localizedDescription {
                    NavigationLink("Sign in on iPhone", value: WatchRoute.account)
                }
            } else if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if !hasLatest {
                rows
            }
        }
        .navigationTitle(title)
        .task(id: LoadID(route: route, session: ObjectIdentifier(library.session), attempt: attempt)) {
            loading = true; error = nil; showingCache = false
            if route == .latest { _ = library.restoreWatchArchives(library.followedShows) }
            do {
                _ = try await library.sessionForRequest()
                switch route {
                case .latest: try await library.loadArchive()
                case .show(let show): try await library.load(show)
                default: break
                }
                try Task.checkCancellation()
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                if error is URLError, library.restoreWatchCatalog() {
                    switch route {
                    case .show(let show): showingCache = library.restoreWatchArchives([show])
                    case .latest: showingCache = library.restoreWatchArchives(library.followedShows)
                    default: showingCache = true
                    }
                }
                if !showingCache { self.error = LibraryError.message(for: error) }
                loading = false
            }
        }
    }

    @ViewBuilder private var rows: some View {
        switch route {
        case .allShows:
            ForEach(library.shows) { WatchShowRow(show: $0) }
        case .following:
            if library.followedShows.isEmpty { emptySubscriptions }
            else { ForEach(library.followedShows.sorted(by: Show.alphabetical)) { WatchShowRow(show: $0) } }
        case .latest:
            if library.subscriptions.isEmpty { emptySubscriptions }
            else if library.feed.isEmpty { Text("No Episodes in Your Followed Shows") }
            WatchEpisodeRows(episodes: library.feed, source: .latestEpisodes)
        case .show(let show):
            let episodes = library.episodes[show.id] ?? []
            if episodes.isEmpty { Text("No Episodes Yet") }
            WatchEpisodeRows(episodes: episodes, source: .show(show.id))
        default: EmptyView()
        }
    }

    @ViewBuilder private var emptySubscriptions: some View {
        Text("No Followed Shows")
        if library.account == nil { NavigationLink("Sign in on iPhone", value: WatchRoute.account) }
        else { NavigationLink("Browse Shows", value: WatchRoute.allShows) }
    }

    private struct LoadID: Hashable { let route: WatchRoute; let session: ObjectIdentifier; let attempt: Int }
}

struct WatchSearch: View {
    @Environment(PodcastLibrary.self) private var library
    @State private var query = ""
    @State private var results = [Episode]()
    @State private var error: String?
    @State private var searching = false
    @State private var retry = 0

    var body: some View {
        List {
            TextField("Search episodes", text: $query)
            if query.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 { Text("Enter at least 3 characters.") }
            else if searching { ProgressView("Searching…") }
            else if let error {
                Text(error)
                Button("Try Again") { retry += 1 }
            } else if results.isEmpty { Text("No Results") }
            else {
                ForEach(results) { episode in WatchEpisodeRow(episode: episode, source: .show(episode.showID)) }
            }
        }
        .navigationTitle("Search")
        .task(id: SearchID(term: query, attempt: retry, session: ObjectIdentifier(library.session))) {
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            results = []; error = nil; searching = term.count >= 3
            guard searching else { return }
            do {
                try await Task.sleep(for: .milliseconds(300))
                let result = try await library.sessionForRequest().searchEpisodes(term)
                try Task.checkCancellation()
                results = result
            } catch {
                guard !Task.isCancelled else { return }
                self.error = LibraryError.message(for: error)
            }
            searching = false
        }
    }

    private struct SearchID: Hashable { let term: String; let attempt: Int; let session: ObjectIdentifier }
}
