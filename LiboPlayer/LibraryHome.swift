import SwiftUI

extension View {
    func leadingTitle(_ title: Text) -> some View {
        modifier(LeadingNavigationTitle(title: title))
    }
}

private struct LeadingNavigationTitle: ViewModifier {
    let title: Text
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
    case shows, categories, saved, downloaded, latestEpisodes

    var title: LocalizedStringResource {
        switch self {
        case .shows: "Shows"
        case .categories: "Categories"
        case .saved: "Saved"
        case .downloaded: "Downloaded"
        case .latestEpisodes: "Latest Episodes"
        }
    }

    var icon: String {
        switch self {
        case .shows: "square.stack"
        case .categories: "square.3.layers.3d"
        case .saved: "bookmark"
        case .downloaded: "arrow.down.circle"
        case .latestEpisodes: "clock"
        }
    }
}

struct LibraryHome: View {
    @Environment(PodcastLibrary.self) private var library
    let signIn: () -> Void
    let openShow: (Show) -> Void

    var body: some View {
        let recent = Show.recentlyUpdated(library.followedShows, archives: library.episodes)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                VStack(spacing: 0) {
                    ForEach(LibrarySection.allCases, id: \.self) { section in
                        sectionLink(section)
                    }
                }
                .overlay(alignment: .top) { sectionDivider }
                .padding(.bottom, recent.isEmpty ? 0 : 22)
                if !recent.isEmpty {
                    Section {
                        ShowGrid(shows: recent, showsDate: true, signIn: signIn, openShow: openShow)
                    } header: {
                        Text("Recently Updated")
                            .font(.headline).foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                            .background(.background)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
        }
        .refreshable { await library.refresh() }
    }

    private func sectionLink(_ section: LibrarySection) -> some View {
        NavigationLink(value: section) {
            HStack(spacing: 16) {
                Image(systemName: section.icon)
                    .font(.title3).foregroundStyle(.tint)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(section.title)
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { sectionDivider }
    }

    private var sectionDivider: some View {
        Divider().padding(.leading, 56).padding(.trailing, 16)
    }
}

struct ShowGrid: View {
    let shows: [Show]
    var showsDate = false
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
            if showsDate, let time = show.lastEpisode {
                Text("Updated \(Date(timeIntervalSince1970: time), style: .relative) ago")
                    .font(.caption).foregroundStyle(.secondary)
            }
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

struct CategoryList: View {
    @Environment(PodcastLibrary.self) private var library
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        let populated = library.categories.filter { !library.followedShows(in: $0).isEmpty }
        List(populated) { category in
            NavigationLink(value: category) {
                HStack {
                    Text(category.name)
                    Spacer()
                    Text(library.followedShows(in: category).count, format: .number)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if let error {
                ContentUnavailableView { Label("Couldn’t Load Categories", systemImage: "exclamationmark.circle") }
                    description: { Text(error) }
                    actions: { Button("Try Again") { retry += 1 } }
            } else if !library.ready || (!library.followedShows.isEmpty && populated.isEmpty && library.categoryMembers.count < library.categories.count) {
                ProgressView("Loading categories…")
            } else if populated.isEmpty {
                ContentUnavailableView("No Categories in Your Followed Shows", systemImage: "square.3.layers.3d")
            }
        }
        .task(id: Request(session: ObjectIdentifier(library.session), retry: retry, hasShows: !library.followedShows.isEmpty)) {
            error = nil
            guard !library.ready || !library.followedShows.isEmpty else { return }
            do { try await library.loadCategories() }
            catch { if !Task.isCancelled { self.error = LibraryError.message(for: error) } }
        }
    }

    private struct Request: Equatable { let session: ObjectIdentifier; let retry: Int; let hasShows: Bool }
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
