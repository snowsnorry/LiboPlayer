import SwiftUI

private enum LibraryTab: CaseIterable {
    case allShows, library, search
    var title: LocalizedStringResource {
        switch self { case .allShows: "All Shows"; case .library: "Library"; case .search: "Search" }
    }
    var icon: String {
        switch self { case .allShows: "square.grid.2x2"; case .library: "rectangle.stack"; case .search: "magnifyingglass" }
    }
}

private struct PlayerEpisodeDestination: Hashable {
    let episode: Episode
    let source: QueueSource
}

private extension View {
    @ViewBuilder func signInDialog<Dialog: View>(isPresented: Binding<Bool>, onDismiss: @escaping () -> Void,
                                                   @ViewBuilder content: @escaping () -> Dialog) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
        } else {
            sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
        }
    }

    @ViewBuilder func tabRootTitle(_ title: LocalizedStringResource) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            navigationTitle(Text(verbatim: "")).navigationBarTitleDisplayMode(.inline)
        } else {
            leadingTitle(Text(title))
        }
    }
}

struct LibraryScreen: View {
    @Environment(PodcastLibrary.self) private var library
    @Environment(PodcastPlayer.self) private var player
    @Environment(\.scenePhase) private var phase
    @State private var tab = LibraryTab.allShows
    @State private var path = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var login = false
    @State private var showingProfile = false
    @State private var restoringPreviousLogin = false
    @State private var archiveError: String?
    @State private var archiveRetry = 0
    @State private var showSearch = ""
    @State private var catalogSearch = ""

    var body: some View {
        tabsWithPlayer
            .task {
                guard !library.ready else { return }
                do {
                    if try StudioCredential.saved() == nil, !StudioCredential.didSignOut, await SignInPage.hasPreviousLoginStorage() {
                        restoringPreviousLogin = true
                        login = true
                    } else { await library.refresh(quietIfCached: true) }
                } catch { library.message = LibraryError.message(for: error) }
            }
            .task(id: ArchiveKey(session: ObjectIdentifier(library.session), shows: library.subscriptions.keys.sorted(), retry: archiveRetry)) {
                archiveError = nil
                do { try await library.loadArchive() }
                catch { if !Task.isCancelled { archiveError = LibraryError.message(for: error) } }
            }
            .task(id: phase == .active ? library.account : nil) {
                if phase == .active { await player.refreshListeningWhileActive() }
            }
            .onChange(of: library.account) { _, id in
                libraryPath = NavigationPath()
                player.useAccount(id)
            }
            .onChange(of: phase) { _, phase in if phase != .active { player.save() } }
            .sheet(isPresented: Binding(get: { player.expanded }, set: { player.expanded = $0 })) { PlayerSheet().presentationDragIndicator(.visible) }
            .sheet(isPresented: $showingProfile) { AccountProfileScreen() }
            .signInDialog(isPresented: $login, onDismiss: {
                restoringPreviousLogin = false
                if !library.ready { Task { await library.refresh() } }
            }) { SignInPage(restoringPreviousLogin: restoringPreviousLogin) }
            .alert("Libo/Libo", isPresented: Binding(get: { library.message != nil || player.message != nil },
                   set: { if !$0 { library.message = nil; player.message = nil } })) {
                Button("Close", role: .cancel) {}
            } message: { Text(player.message ?? library.message ?? "") }
            .tint(.accentColor)
    }

    @ViewBuilder private var tabsWithPlayer: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            if #available(iOS 18.0, *) {
                modernTabs
                    .safeAreaInset(edge: .bottom, spacing: 0) { padPlayer }
            } else {
                legacyTabs
            }
        } else if #available(iOS 26.1, *) {
            floatingTabs.tabViewBottomAccessory(isEnabled: player.current != nil) { MiniPlayerAccessory() }
        } else if #available(iOS 26.0, *) {
            if player.current != nil {
                floatingTabs.tabViewBottomAccessory { MiniPlayerAccessory() }
            } else {
                floatingTabs
            }
        } else {
            legacyTabs
        }
    }

    private var legacyTabs: some View {
        TabView(selection: $tab) {
            ForEach(LibraryTab.allCases, id: \.self) { item in
                screen(for: item)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if UIDevice.current.userInterfaceIdiom == .pad {
                            padPlayer
                        } else if player.current != nil {
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

    @ViewBuilder private var padPlayer: some View {
        if let episode = player.current {
            PadMiniPlayer(episode: episode, openDetails: {
                navigationPath(for: tab).wrappedValue.append(PlayerEpisodeDestination(episode: episode, source: player.source))
            }, openShow: { show in
                navigationPath(for: tab).wrappedValue.append(show)
            })
        }
    }

    @available(iOS 26.0, *)
    private var floatingTabs: some View {
        modernTabs.tabBarMinimizeBehavior(.onScrollDown)
    }

    @available(iOS 18.0, *)
    private var modernTabs: some View {
        TabView(selection: $tab) {
            Tab("All Shows", systemImage: LibraryTab.allShows.icon, value: LibraryTab.allShows) { screen(for: .allShows) }
            Tab("Library", systemImage: LibraryTab.library.icon, value: LibraryTab.library) { screen(for: .library) }
            Tab(value: LibraryTab.search, role: .search) { screen(for: .search) }
        }
    }

    private func navigationPath(for item: LibraryTab) -> Binding<NavigationPath> {
        switch item {
        case .allShows: $path
        case .library: $libraryPath
        case .search: $searchPath
        }
    }

    private func screen(for item: LibraryTab) -> some View {
        NavigationStack(path: navigationPath(for: item)) {
            tabRoot(for: item)
                .navigationDestination(for: Show.self) { ShowScreen(show: $0, signIn: { login = true }) }
                .navigationDestination(for: PlayerEpisodeDestination.self) { destination in
                    EpisodeDetails(episode: destination.episode, source: destination.source)
                }
        }
    }

    @ViewBuilder private func tabRoot(for item: LibraryTab) -> some View {
        switch item {
        case .allShows:
            Group {
                if library.ready { allShowsGrid }
                else { catalogLoading }
            }
            .searchable(text: $showSearch, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search show titles")
            .tabRootTitle(item.title)
            .toolbar { profileToolbarItem }
        case .library:
            LibraryHome(archiveError: archiveError, retryArchive: { archiveRetry += 1 },
                        signIn: { login = true }, browseShows: browseShows, profileButton: profileButton,
                        openSection: { libraryPath.append($0) }, openShow: { libraryPath.append($0) })
                .navigationDestination(for: LibrarySection.self) { section in
                    Group {
                        switch section {
                        case .following: followedShowsGrid
                        case .saved, .downloaded: CollectionEpisodes(section: section) { libraryPath.append($0) }
                        }
                    }.leadingTitle(Text(section.title))
                }
        case .search:
            Group {
                if library.ready { EpisodeSearchScreen(query: $catalogSearch) { searchPath.append($0) } }
                else { catalogLoading }
            }
            .tabRootTitle(item.title)
            .toolbar { profileToolbarItem }
        }
    }

    private var profileToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { profileButton }
    }

    private var profileButton: some View {
        Button {
            if library.isSignedIn { showingProfile = true }
            else { login = true }
        } label: {
            Image(systemName: library.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle.badge.plus")
                .foregroundStyle(.blue)
        }
        .accessibilityLabel(library.isSignedIn ? Text("Libo/Libo Account") : Text("Sign in with Telegram"))
    }

    @ViewBuilder private var catalogLoading: some View {
        if library.busy { ProgressView("Loading shows…") }
        else { Button("Load Shows") { Task { await library.refresh() } } }
    }

    private var allShowsGrid: some View {
        let term = showSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let shows = term.isEmpty ? library.shows : library.shows.filter { $0.name.localizedStandardContains(term) }
        return ScrollView {
            ShowGrid(shows: shows, signIn: { login = true }) { path.append($0) }
                .padding(.bottom, 24)
        }
        .overlay {
            if !term.isEmpty && shows.isEmpty { ContentUnavailableView.search(text: term) }
        }
        .refreshable { await library.refresh() }
    }

    @ViewBuilder private var followedShowsGrid: some View {
        if !library.ready { catalogLoading }
        else if library.account == nil {
            ContentUnavailableView { Label("No Followed Shows", systemImage: "heart") }
                actions: { Button("Sign in with Telegram") { login = true } }
        } else if library.followedShows.isEmpty {
            ContentUnavailableView { Label("No Followed Shows", systemImage: "heart") }
                actions: { Button("Browse Shows", action: browseShows) }
        } else {
            ScrollView {
                ShowGrid(shows: library.followedShows.sorted(by: Show.alphabetical), signIn: { login = true }) { libraryPath.append($0) }
            }.refreshable { await library.refresh() }
        }
    }

    private func browseShows() {
        path = NavigationPath()
        tab = .allShows
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
                else { EpisodeList(episodes: rows, source: .show(show.id), query: $episodeQuery, openShow: nil) }
            } else if let loadError {
                ContentUnavailableView { Label("Couldn’t Load Episodes", systemImage: "exclamationmark.circle") }
                    description: { Text(loadError) }
                    actions: { Button("Retry Loading Episodes") { retry += 1 } }
            }
            else { ProgressView("Loading episodes…") }
        }
        .searchable(text: $episodeQuery.title, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search episode titles")
        .leadingTitle(Text(verbatim: show.name))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShowFollowButton(show: show, signIn: signIn)
                    .labelStyle(.iconOnly)
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
