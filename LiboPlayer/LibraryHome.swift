import SwiftUI
import UIKit

extension View {
    func leadingTitle(_ title: some View) -> some View {
        modifier(LeadingNavigationTitle(title: title))
    }
}

private struct LeadingNavigationTitle<Title: View>: ViewModifier {
    let title: Title
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        // Leave room for the native back button, two actions, and their navigation bar margins.
        let heading = title.font(.headline).foregroundStyle(.primary).lineLimit(1)
            .frame(maxWidth: width > 0 ? max(44, width / 2 - 48) : 128, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityAddTraits(.isHeader)
        content
            // Loading indicators have an intrinsic width smaller than the navigation bar.
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .navigationTitle(Text(verbatim: "")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if #available(iOS 26, *) {
                    ToolbarItem(placement: .topBarLeading) { heading }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) { heading }
                }
            }
    }
}

enum LibrarySection: CaseIterable, Hashable {
    case following, saved, downloaded

    var title: LocalizedStringResource {
        switch self {
        case .following: "Following"
        case .saved: "Saved"
        case .downloaded: "Downloaded"
        }
    }

    var icon: String {
        switch self {
        case .following: "heart"
        case .saved: "bookmark"
        case .downloaded: "arrow.down.circle"
        }
    }
}

struct LibraryHome<ProfileButton: View>: View {
    @Environment(PodcastLibrary.self) private var library
    @Environment(PodcastPlayer.self) private var player
    @State private var query = EpisodeQuery()
    @State private var selectedEpisode: Episode?
    @State private var searchBarHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var navigationTitleFrame: CGRect?
    @State private var episodeTitleInset: CGFloat = 16
    @State private var titlesMeet = false

    let archiveError: String?
    let retryArchive: () -> Void
    let signIn: () -> Void
    let browseShows: () -> Void
    let profileButton: ProfileButton
    let openShow: (Show) -> Void

    private var hasEpisodes: Bool {
        library.ready && library.account != nil && !library.subscriptions.isEmpty
            && archiveError == nil && library.archiveReady && !library.feed.isEmpty
    }

    var body: some View {
        let compact = hasEpisodes && titlesMeet
        List {
            ForEach(LibrarySection.allCases, id: \.self) { section in
                NavigationLink(value: section) {
                    Label {
                        Text(section.title)
                    } icon: {
                        Image(systemName: section.icon).foregroundStyle(.tint)
                    }
                    .frame(minHeight: 44)
                }
            }

            // This row scrolls through the navigation bar. Only the search field pins.
            HStack {
                Text("Latest Episodes")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .onGeometryChange(for: Bool.self) { geometry in
                        guard let navigationTitleFrame else { return false }
                        return geometry.frame(in: .global).minY <= navigationTitleFrame.maxY
                    } action: { titlesMeet = $0 }
                Spacer()
                if hasEpisodes {
                    EpisodeFilterMenu(filter: $query.filter)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            .opacity(compact ? 0 : 1)
            .accessibilityHidden(compact)
            .allowsHitTesting(!compact)
            .padding(.leading, episodeTitleInset)
            .onGeometryChange(for: CGFloat.self) { geometry in
                guard let navigationTitleFrame else { return 16 }
                let row = geometry.frame(in: .global)
                let inset = layoutDirection == .leftToRight
                    ? navigationTitleFrame.minX - row.minX
                    : row.maxX - navigationTitleFrame.maxX
                return max(0, inset)
            } action: { episodeTitleInset = $0 }
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
            .listRowSeparator(.hidden)

            Section {
                if hasEpisodes {
                    episodeResults
                } else {
                    feedStatus
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                }
            } header: {
                if hasEpisodes {
                    Color.clear
                        .frame(height: searchBarHeight)
                        .anchorPreference(key: SearchBarBounds.self, value: .bounds) { $0 }
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        // Keep the editing control outside recycled list cells so filtering retains keyboard focus.
        .overlayPreferenceValue(SearchBarBounds.self) { anchor in
            if let anchor {
                GeometryReader { geometry in
                    let bounds = geometry[anchor]
                    EpisodeSearchBar(text: $query.title)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: bounds.width)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { searchBarHeight = $0 }
                        .offset(x: bounds.minX, y: bounds.minY)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await library.refresh() }
        .navigationDestination(item: $selectedEpisode) { episode in
            EpisodeDetails(episode: episode, source: .latestEpisodes)
        }
        .onChange(of: library.account) { query = EpisodeQuery() }
        .leadingTitle(
            // Reserve a single title slot so the text slides vertically without shifting sideways.
            Text("Latest Episodes").hidden()
                .overlay(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        if compact {
                            Text("Latest Episodes").transition(.move(edge: .bottom))
                        } else {
                            Text("Library").transition(.move(edge: .top))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .clipped()
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: compact)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { navigationTitleFrame = $0 }
        )
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if compact { EpisodeFilterMenu(filter: $query.filter) }
                profileButton
            }
        }
    }

    @ViewBuilder private var episodeResults: some View {
        let results = query.results(in: library.feed, isFinished: player.isFinished)
        if results.isEmpty {
            ContentUnavailableView("No Matching Episodes", systemImage: "magnifyingglass",
                                   description: Text("Try another title or listening status."))
                .listRowSeparator(.hidden)
        }
        ForEach(results) { episode in
            EpisodeListRow(episode: episode, source: .latestEpisodes, openShow: openShow) {
                selectedEpisode = episode
            }
        }
    }

    @ViewBuilder private var feedStatus: some View {
        if !library.ready {
            if library.busy { ProgressView("Loading shows…") }
            else { Button("Load Shows") { Task { await library.refresh() } } }
        } else if library.account == nil {
            VStack(spacing: 12) {
                Text("Sign in to see episodes from the shows you follow.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Sign in with Telegram", action: signIn).buttonStyle(.bordered)
            }
            .padding(.vertical)
        } else if library.subscriptions.isEmpty {
            ContentUnavailableView { Label("No Followed Shows", systemImage: "heart") }
                actions: { Button("Browse Shows", action: browseShows) }
        } else if let archiveError {
            ContentUnavailableView { Label("Couldn’t Load Episodes", systemImage: "exclamationmark.circle") }
                description: { Text(archiveError) }
                actions: { Button("Try Again", action: retryArchive) }
        } else if !library.archiveReady {
            ProgressView("Loading episodes…")
        } else {
            ContentUnavailableView("No Episodes in Your Followed Shows", systemImage: "rectangle.stack")
        }
    }
}

private struct SearchBarBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct EpisodeSearchBar: UIViewRepresentable {
    @Binding var text: String
    @Environment(\.locale) private var locale

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UISearchBar {
        let bar = UISearchBar()
        bar.searchBarStyle = .minimal
        bar.enablesReturnKeyAutomatically = false
        bar.delegate = context.coordinator
        return bar
    }

    func updateUIView(_ bar: UISearchBar, context: Context) {
        context.coordinator.text = $text
        bar.placeholder = String(localized: "Search episode titles", locale: locale)
        if bar.text != text { bar.text = text }
    }

    final class Coordinator: NSObject, UISearchBarDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            text.wrappedValue = searchText
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            searchBar.resignFirstResponder()
        }
    }
}

struct ShowGrid: View {
    let shows: [Show]
    let signIn: () -> Void
    let openShow: (Show) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let column = GridItem(.flexible(), spacing: 0, alignment: .top)
        LazyVGrid(columns: typeSize.isAccessibilitySize ? [column] : [column, column], alignment: .leading, spacing: 6) {
            ForEach(shows) { show in
                Button { openShow(show) } label: {
                    tile(for: show)
                        .padding(8)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .tint(.primary)
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16))
                .contextMenu {
                    ControlGroup {
                        ShowFollowButton(show: show, signIn: signIn)
                        ShareLink(item: StudioSite.home.appending(queryItems: [URLQueryItem(name: "start", value: "feed_\(show.id)")])) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                    Divider()
                    Button("Go to Show", systemImage: "dot.radiowaves.left.and.right") { openShow(show) }
                } preview: {
                    tile(for: show)
                        .padding(16)
                        .frame(idealWidth: 360)
                }
            }
        }
        .padding(.horizontal, 10)
    }

    private func tile(for show: Show) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Cover(artwork: show.artwork, radius: 12)
            Text(show.name).font(.subheadline.weight(.semibold)).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ShowFollowButton: View {
    @Environment(PodcastLibrary.self) private var library
    let show: Show
    let signIn: () -> Void

    var body: some View {
        let followed = library.subscriptions[show.id] != nil
        let title: LocalizedStringKey = followed ? "Unfollow Show" : "Follow Show"
        Button(title, systemImage: followed ? "heart.fill" : "heart") {
            if library.account == nil { signIn() }
            else { Task { await library.toggle(show) } }
        }
        .disabled(!library.changing.isEmpty || library.busy)
    }
}

struct CollectionEpisodes: View {
    @Environment(PodcastLibrary.self) private var library
    let section: LibrarySection
    let openShow: (Show) -> Void
    @State private var query = EpisodeQuery()

    var body: some View {
        let saved = section == .saved
        let rows = saved ? library.collection.saved : library.collection.downloaded
        Group {
            if rows.isEmpty {
                if saved { ContentUnavailableView("No Saved Episodes", systemImage: "bookmark") }
                else { ContentUnavailableView("No Downloaded Episodes", systemImage: "arrow.down.circle") }
            } else {
                EpisodeList(episodes: rows, source: saved ? .saved : .downloaded, query: $query, openShow: openShow)
            }
        }
        .searchable(text: $query.title, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search episode titles")
    }
}
