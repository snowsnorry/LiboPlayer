import SwiftUI

struct PadLibraryFeed<Status: View>: View {
    @Environment(PodcastPlayer.self) private var player
    @Environment(\.dynamicTypeSize) private var typeSize
    let episodes: [Episode]
    @Binding var query: EpisodeQuery
    let openSection: (LibrarySection) -> Void
    let openShow: (Show) -> Void
    let openDetails: (Episode) -> Void
    @ViewBuilder let status: () -> Status

    private enum Row: Hashable {
        case library, controls, episode(String)
    }

    private struct SearchBounds: PreferenceKey {
        static var defaultValue: [Row: Anchor<CGRect>] { [:] }
        static func reduce(value: inout [Row: Anchor<CGRect>], nextValue: () -> [Row: Anchor<CGRect>]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    @State private var narrow = false
    @State private var linksHeight: CGFloat = 0
    @State private var editingSearch = false
    @State private var controlsHeight: CGFloat = 52
    @State private var beforeSearchID: String?

    var body: some View {
        let results = query.results(in: episodes, isFinished: player.isFinished)
        ScrollViewReader { proxy in
            let list = List {
                introduction
                    .padding(.top, 8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { linksHeight = $0 }
                    .background { searchMarker(.library) }
                    .id(Row.library)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)

                Section {
                    if episodes.isEmpty {
                        status().frame(maxWidth: .infinity).listRowSeparator(.hidden)
                    } else if results.isEmpty {
                        ContentUnavailableView("No Matching Episodes", systemImage: "magnifyingglass",
                                               description: Text("Try another title or listening status."))
                            .listRowSeparator(.hidden)
                    }
                    ForEach(results) { episode in
                        EpisodeListRow(episode: episode, source: .latestEpisodes, openShow: openShow) {
                            openDetails(episode)
                        }
                        .background { searchMarker(.episode(episode.id)) }
                    }
                } header: {
                    sectionHeader(stacked: narrow || typeSize.isAccessibilitySize)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 4)
                        .listRowInsets(EdgeInsets())
                }
            }
            .listStyle(.plain)
            .listSectionSpacing(0)
            .onGeometryChange(for: Bool.self) { $0.size.width < 590 } action: { narrow = $0 }
            .overlayPreferenceValue(SearchBounds.self) { bounds in
                GeometryReader { geometry in
                    let slot = bounds[.controls].map { geometry[$0] } ?? .zero
                    let origin = editingSearch && query.title.isEmpty
                        ? searchOrigin(in: bounds, below: slot.maxY + 4, geometry: geometry) : nil
                    searchControls(origin: origin)
                        .frame(width: slot.width)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
                        .position(x: slot.midX, y: slot.midY)
                        .opacity(slot.isEmpty ? 0 : 1)
                }
            }
            .onChange(of: query.title) { old, new in
                if !old.isEmpty && new.isEmpty {
                    if let beforeSearchID, results.contains(where: { $0.id == beforeSearchID }) {
                        proxy.scrollTo(beforeSearchID, anchor: .top)
                    } else {
                        proxy.scrollTo(Row.library, anchor: .top)
                    }
                    beforeSearchID = nil
                }
            }

            if #available(iOS 26, *) {
                list.modifier(PadFeedScrollEdge(linksHeight: linksHeight))
            } else {
                list
            }
        }
    }

    // Only collect row anchors while the search field is focused and still empty.
    @ViewBuilder private func searchMarker(_ row: Row) -> some View {
        if editingSearch && query.title.isEmpty {
            Color.clear.anchorPreference(key: SearchBounds.self, value: .bounds) { [row: $0] }
        }
    }

    private func searchOrigin(in bounds: [Row: Anchor<CGRect>], below headerBottom: CGFloat,
                              geometry: GeometryProxy) -> String? {
        if let links = bounds[.library], geometry[links].maxY > 0 { return nil }
        let visible = bounds.compactMap { row, anchor -> (id: String, rect: CGRect)? in
            guard case let .episode(id) = row else { return nil }
            let rect = geometry[anchor]
            return rect.maxY > headerBottom && rect.minY < geometry.size.height ? (id, rect) : nil
        }
        return visible.min(by: { $0.rect.minY < $1.rect.minY })?.id
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) { collectionLinks }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 0) { collectionLinks }
            }
            Divider()
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder private var collectionLinks: some View {
        ForEach(LibrarySection.allCases, id: \.self) { section in
            Button { openSection(section) } label: {
                HStack(spacing: 6) {
                    Image(systemName: section.icon)
                    Text(section.title)
                    Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .font(.headline)
                .foregroundStyle(.blue)
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
        }
    }

    private func sectionHeader(stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                             : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Text("Latest Episodes")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Color.clear
                .frame(maxWidth: stacked ? .infinity : 348)
                .frame(height: controlsHeight)
                .anchorPreference(key: SearchBounds.self, value: .bounds) { [.controls: $0] }
                .accessibilityHidden(true)
        }
    }

    // List can recycle its section header while filtering. Keep one live text field above its slot.
    private func searchControls(origin: String?) -> some View {
        HStack(spacing: 4) {
            EpisodeSearchBar(text: Binding(get: { query.title }, set: { text in
                if query.title.isEmpty && !text.isEmpty { beforeSearchID = origin }
                query.title = text
            }), editingChanged: { editingSearch = $0 })
            .fixedSize(horizontal: false, vertical: true)
            EpisodeFilterMenu(filter: $query.filter)
        }
        .disabled(episodes.isEmpty)
    }
}

@available(iOS 26, *)
private struct PadFeedScrollEdge: ViewModifier {
    let linksHeight: CGFloat
    @State private var headerPinned = false

    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectHidden(!headerPinned, for: .top)
            .onScrollGeometryChange(for: Bool.self) { scroll in
                linksHeight > 0 && scroll.contentOffset.y + scroll.contentInsets.top >= linksHeight
            } action: { _, pinned in headerPinned = pinned }
    }
}
