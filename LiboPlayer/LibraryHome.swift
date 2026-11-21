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

    var body: some View {
        let recent = Show.recentlyUpdated(library.followedShows, archives: library.episodes)
        List {
            ForEach(LibrarySection.allCases, id: \.self) { section in
                NavigationLink(value: section) {
                    Label { Text(section.title) } icon: { Image(systemName: section.icon).foregroundStyle(.tint) }
                }
            }
            if !recent.isEmpty {
                Section {
                    ShowGrid(shows: recent, showsDate: true)
                        .listRowSeparator(.hidden)
                } header: {
                    Text("Recently Updated").font(.headline).foregroundStyle(.primary).textCase(nil)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await library.refresh() }
    }
}

struct ShowGrid: View {
    let shows: [Show]
    var showsDate = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let column = GridItem(.flexible(), spacing: 16, alignment: .top)
        LazyVGrid(columns: typeSize.isAccessibilitySize ? [column] : [column, column], alignment: .leading, spacing: 22) {
            ForEach(shows) { show in
                NavigationLink(value: show) {
                    VStack(alignment: .leading, spacing: 5) {
                        Cover(artwork: show.artwork, radius: 12)
                        Text(show.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                        if showsDate, let time = show.lastEpisode {
                            Text("Updated \(Date(timeIntervalSince1970: time), style: .relative) ago")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .tint(.primary)
            }
        }
        .navigationLinkIndicatorVisibility(.hidden)
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
    @State private var query = EpisodeQuery()

    var body: some View {
        let saved = section == .saved
        let rows = saved ? library.collection.saved : library.collection.downloaded
        Group {
            if rows.isEmpty {
                if saved { ContentUnavailableView("No Saved Episodes", systemImage: "bookmark") }
                else { ContentUnavailableView("No Downloaded Episodes", systemImage: "arrow.down.circle") }
            } else {
                EpisodeList(episodes: rows, source: saved ? .saved : .downloaded, query: $query)
            }
        }
        .searchable(text: $query.title, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search episode titles")
    }
}
