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
    @State private var archiveError = false
    @State private var archiveRetry = 0
    @State private var showSearch = ""
    @State private var catalogSearch = ""
    @State private var episodeQuery = EpisodeQuery()

    var body: some View {
        VStack(spacing: 0) {
            NavigationStack(path: $path) {
                Group {
                    if !library.ready {
                        if library.busy { ProgressView("Loading shows…") }
                        else { Button("Load Shows") { Task { await library.refresh() } } }
                    } else {
                        switch tab {
                        case .shows: showsGrid
                        case .episodes: myEpisodes
                        case .search: EpisodeSearchScreen(query: $catalogSearch)
                        }
                    }
                }
                .navigationTitle(Text(tab.title))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if tab == .shows {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { login = true } label: {
                                Image(systemName: library.account == nil ? "person.crop.circle.badge.plus" : "person.crop.circle.fill")
                            }.accessibilityLabel(library.account == nil ? Text("Sign in with Telegram") : Text("Libo/Libo Account"))
                        }
                    }
                }
                .navigationDestination(for: Show.self) { ShowScreen(show: $0, signIn: { login = true }) }
            }
            .id(tab)
            bottomBar
        }
        .task { if !library.ready { await library.refresh() } }
        .task(id: ArchiveKey(session: ObjectIdentifier(library.session), shows: library.subscriptions.keys.sorted(), retry: archiveRetry)) {
            archiveError = false
            do { try await library.loadArchive() }
            catch { if !Task.isCancelled { archiveError = true } }
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

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if player.current != nil { MiniPlayer() }
            Divider()
            HStack {
                ForEach(LibraryTab.allCases, id: \.self) { item in
                    Button {
                        path.removeAll()
                        tab = item
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.icon).font(.system(size: 19, weight: .medium))
                            Text(item.title).font(.caption2.weight(.medium))
                        }.frame(maxWidth: .infinity, minHeight: 45)
                    }
                    .foregroundStyle(tab == item ? Color.accentColor : .secondary)
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }.padding(.top, 4)
        }.background(.regularMaterial)
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
        .searchable(text: $showSearch, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search show titles")
        .refreshable { await library.refresh() }
    }

    @ViewBuilder private var myEpisodes: some View {
        if library.account == nil {
            ContentUnavailableView { Label("My Episodes", systemImage: "heart") }
                description: { Text("Sign in to see episodes from the shows you follow.") }
                actions: { Button("Sign in with Telegram") { login = true } }
        } else if library.subscriptions.isEmpty {
            ContentUnavailableView { Label("No Followed Shows", systemImage: "heart") }
                actions: { Button("Browse Shows") { tab = .shows } }
        } else if archiveError {
            ContentUnavailableView { Label("Couldn’t Load Episodes", systemImage: "wifi.exclamationmark") }
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

    private struct ArchiveKey: Equatable { let session: ObjectIdentifier; let shows: [String]; let retry: Int }
}

private struct ShowScreen: View {
    @Environment(PodcastLibrary.self) private var library
    let show: Show
    let signIn: () -> Void
    @State private var loadFailed = false
    @State private var retry = 0
    @State private var episodeQuery = EpisodeQuery()
    var body: some View {
        Group {
            if let rows = library.episodes[show.id] {
                if rows.isEmpty { ContentUnavailableView("No Episodes Yet", systemImage: "waveform") }
                else { EpisodeList(episodes: rows, source: .show(show.id), query: $episodeQuery) }
            } else if loadFailed { Button("Retry Loading Episodes") { retry += 1 } }
            else { ProgressView("Loading episodes…") }
        }
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
            loadFailed = false
            do { try await library.load(show) }
            catch { if !Task.isCancelled { loadFailed = true } }
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
