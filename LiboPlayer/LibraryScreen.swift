import SwiftUI

private enum LibraryTab: CaseIterable {
    case shows, episodes, search
    var title: LocalizedStringResource {
        switch self { case .shows: "Shows"; case .episodes: "My Episodes"; case .search: "Search" }
    }
    var icon: String {
        switch self { case .shows: "square.grid.2x2"; case .episodes: "rectangle.stack"; case .search: "magnifyingglass" }
    }
}

struct LibraryScreen: View {
    @Environment(PodcastLibrary.self) private var library
    @Environment(PodcastPlayer.self) private var player
    @Environment(\.scenePhase) private var phase
    @State private var tab = LibraryTab.shows
    @State private var path: [Show] = []
    @State private var login = false
    @State private var archiveError: String?
    @State private var archiveRetry = 0
    @State private var showSearch = ""
    @State private var catalogSearch = ""
    @State private var episodeQuery = EpisodeQuery()

    var body: some View {
        tabsWithPlayer
            .task { if !library.ready { await library.refresh() } }
            .task(id: ArchiveKey(session: ObjectIdentifier(library.session), shows: library.subscriptions.keys.sorted(), retry: archiveRetry)) {
                archiveError = nil
                do { try await library.loadArchive() }
                catch { if !Task.isCancelled { archiveError = LibraryError.message(for: error) } }
            }
            .onChange(of: library.account) { _, id in player.useAccount(id) }
            .onChange(of: phase) { _, phase in if phase != .active { player.save() } }
            .sheet(isPresented: Binding(get: { player.expanded }, set: { player.expanded = $0 })) { PlayerSheet().presentationDragIndicator(.visible) }
            .fullScreenCover(isPresented: $login, onDismiss: { Task { await library.refresh() } }) {
                NavigationStack {
                    SignInPage().ignoresSafeArea(edges: .bottom)
                        .navigationTitle("Libo/Libo Account").navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("Done") { login = false } }
                }
            }
            .alert("Libo/Libo", isPresented: Binding(get: { library.message != nil || player.message != nil },
                   set: { if !$0 { library.message = nil; player.message = nil } })) {
                Button("Close", role: .cancel) {}
            } message: { Text(player.message ?? library.message ?? "") }
            .tint(.accentColor)
    }

    @ViewBuilder private var tabsWithPlayer: some View {
        if #available(iOS 26.1, *) {
            floatingTabs.tabViewBottomAccessory(isEnabled: player.current != nil) { MiniPlayerAccessory() }
        } else if #available(iOS 26.0, *) {
            if player.current != nil {
                floatingTabs.tabViewBottomAccessory { MiniPlayerAccessory() }
            } else {
                floatingTabs
            }
        } else {
            TabView(selection: $tab) {
                ForEach(LibraryTab.allCases, id: \.self) { item in
                    screen(for: item)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            if player.current != nil {
                                MiniPlayer(inline: false)
                                    .padding(.vertical, 4)
                                    .background(.regularMaterial)
                            }
                        }
                        .tabItem { Label { Text(item.title) } icon: { Image(systemName: item.icon) } }
                        .tag(item)
                }
            }
        }
    }

    @available(iOS 26.0, *)
    private var floatingTabs: some View {
        TabView(selection: $tab) {
            Tab("Shows", systemImage: LibraryTab.shows.icon, value: LibraryTab.shows) { screen(for: .shows) }
            Tab("My Episodes", systemImage: LibraryTab.episodes.icon, value: LibraryTab.episodes) { screen(for: .episodes) }
            Tab(value: LibraryTab.search, role: .search) { screen(for: .search) }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }

    @ViewBuilder private func screen(for item: LibraryTab) -> some View {
        switch item {
        case .shows:
            NavigationStack(path: $path) {
                Group {
                    if library.ready { showsGrid }
                    else { catalogLoading }
                }
                .searchable(text: $showSearch, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search show titles")
                .navigationTitle(Text(item.title))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { login = true } label: {
                            Image(systemName: library.account == nil ? "person.crop.circle.badge.plus" : "person.crop.circle.fill")
                        }.accessibilityLabel(library.account == nil ? Text("Sign in with Telegram") : Text("Libo/Libo Account"))
                    }
                }
                .navigationDestination(for: Show.self) { ShowScreen(show: $0, signIn: { login = true }) }
            }
        case .episodes:
            NavigationStack {
                myEpisodes
                    .navigationTitle(Text(item.title))
                    .navigationBarTitleDisplayMode(.inline)
            }
        case .search:
            NavigationStack {
                Group {
                    if library.ready { EpisodeSearchScreen(query: $catalogSearch) }
                    else { catalogLoading }
                }
                .navigationTitle(Text(item.title))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    @ViewBuilder private var catalogLoading: some View {
        if library.busy { ProgressView("Loading shows…") }
        else { Button("Load Shows") { Task { await library.refresh() } } }
    }

    private var showsGrid: some View {
        let term = showSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let shows = term.isEmpty ? library.shows : library.shows.filter { $0.name.localizedStandardContains(term) }
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 220), spacing: 16)], alignment: .leading, spacing: 22) {
                ForEach(shows) { show in
                    NavigationLink(value: show) {
                        VStack(alignment: .leading, spacing: 8) {
                            Cover(artwork: show.artwork, radius: 12)
                            Text(show.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 18).padding(.bottom, 24)
        }
        .overlay {
            if !term.isEmpty && shows.isEmpty { ContentUnavailableView.search(text: term) }
        }
        .refreshable { await library.refresh() }
    }

    @ViewBuilder private var myEpisodes: some View {
        if library.ready && library.account == nil {
            ContentUnavailableView { Label("My Episodes", systemImage: "heart") }
                description: { Text("Sign in to see episodes from the shows you follow.") }
                actions: { Button("Sign in with Telegram") { login = true } }
        } else if library.ready && library.subscriptions.isEmpty {
            ContentUnavailableView { Label("No Followed Shows", systemImage: "heart") }
                actions: { Button("Browse Shows") {
                    path.removeAll()
                    tab = .shows
                } }
        } else {
            ZStack {
                if !library.ready { catalogLoading }
                else if let archiveError {
                    ContentUnavailableView { Label("Couldn’t Load Episodes", systemImage: "exclamationmark.circle") }
                        description: { Text(archiveError) }
                        actions: { Button("Try Again") { archiveRetry += 1 } }
                } else if !library.archiveReady {
                    ProgressView("Loading episodes…")
                } else if library.feed.isEmpty {
                    ContentUnavailableView("No Episodes in Your Followed Shows", systemImage: "rectangle.stack")
                } else {
                    EpisodeList(episodes: library.feed, source: .library, query: $episodeQuery)
                        .refreshable { await library.refresh() }
                }
            }
            .searchable(text: $episodeQuery.title, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search episode titles")
        }
    }

    private struct ArchiveKey: Equatable { let session: ObjectIdentifier; let shows: [String]; let retry: Int }
}

private struct ShowScreen: View {
    @Environment(PodcastLibrary.self) private var library
    let show: Show
    let signIn: () -> Void
    @State private var loadError: String?
    @State private var retry = 0
    @State private var episodeQuery = EpisodeQuery()
    var body: some View {
        ZStack {
            if let rows = library.episodes[show.id] {
                if rows.isEmpty { ContentUnavailableView("No Episodes Yet", systemImage: "waveform") }
                else { EpisodeList(episodes: rows, source: .show(show.id), query: $episodeQuery) }
            } else if let loadError {
                ContentUnavailableView { Label("Couldn’t Load Episodes", systemImage: "exclamationmark.circle") }
                    description: { Text(loadError) }
                    actions: { Button("Retry Loading Episodes") { retry += 1 } }
            }
            else { ProgressView("Loading episodes…") }
        }
        .searchable(text: $episodeQuery.title, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search episode titles")
        .navigationTitle(show.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let saved = library.subscriptions[show.id] != nil
                Button {
                    if library.account == nil { signIn() }
                    else { Task { await library.toggle(show) } }
                } label: {
                    Image(systemName: saved ? "heart.fill" : "heart")
                }.accessibilityLabel(saved ? Text("Unfollow Show") : Text("Follow Show"))
                .disabled(!library.changing.isEmpty || library.busy)
            }
        }
        .task(id: "\(ObjectIdentifier(library.session))-\(retry)") {
            loadError = nil
            do { try await library.load(show) }
            catch { if !Task.isCancelled { loadError = LibraryError.message(for: error) } }
        }
    }
}

struct Cover: View {
    let artwork: String?
    let radius: CGFloat
    var body: some View {
        Rectangle().fill(.quaternary).aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncImage(url: artwork.flatMap(URL.init(string:))) { image in image.resizable().scaledToFill() }
                    placeholder: { Image(systemName: "waveform").foregroundStyle(.secondary) }
            }.clipShape(RoundedRectangle(cornerRadius: radius)).accessibilityHidden(true)
    }
}
