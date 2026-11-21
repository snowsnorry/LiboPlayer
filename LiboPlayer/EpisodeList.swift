import SwiftUI

struct EpisodeList: View {
    @Environment(PodcastPlayer.self) private var player
    let episodes: [Episode]
    let source: QueueSource
    @Binding var query: EpisodeQuery

    var body: some View {
        let results = query.results(in: episodes, isFinished: player.isFinished)
        List(results) { episode in
            EpisodeListRow(episode: episode, source: source, showsPodcastName: showsPodcastName)
        }
        .listStyle(.plain)
        .overlay {
            if results.isEmpty {
                ContentUnavailableView("No Matching Episodes", systemImage: "magnifyingglass",
                                       description: Text("Try another title or listening status."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Listening status", selection: $query.filter) {
                        ForEach(EpisodeQuery.Filter.allCases, id: \.self) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    let active = query.filter != .all
                    Label("Filter episodes", systemImage: active
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                        .labelStyle(.iconOnly)
                        .environment(\.symbolVariants, .none)
                        .foregroundStyle(active ? Color.accentColor : .primary)
                }
                .accessibilityValue(Text(query.filter.title))
            }
        }
    }

    private var showsPodcastName: Bool {
        if case .library = source { return true }
        return false
    }
}

struct EpisodeListRow: View {
    @Environment(PodcastLibrary.self) private var library
    @Environment(PodcastPlayer.self) private var player
    let episode: Episode
    let source: QueueSource
    let showsPodcastName: Bool

    var body: some View {
        let played = player.isFinished(episode)
        let show = library.shows.first { $0.id == episode.showID }
        Button { player.select(episode, from: source) } label: {
            EpisodeRow(episode: episode, show: show, showsPodcastName: showsPodcastName, played: played,
                       resumePosition: played ? 0 : player.history.resume(episode),
                       isCurrent: player.current?.id == episode.id)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button {
                Task { await player.mark(episode, played: !played) }
            } label: {
                if played { Label("Mark as Unplayed", systemImage: "arrow.counterclockwise") }
                else { Label("Mark as Played", systemImage: "checkmark") }
            }
            .tint(played ? .indigo : .accentColor)
            .disabled(library.busy || library.updatingPlayed.contains(episode.id))
        }
    }
}

private struct EpisodeRow: View {
    let episode: Episode
    let show: Show?
    let showsPodcastName: Bool
    let played: Bool
    let resumePosition: Double
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Cover(artwork: episode.artwork ?? show?.artwork, radius: 8).frame(width: 56)
            VStack(alignment: .leading, spacing: 4) {
                if showsPodcastName, let show { Text(show.name).font(.caption).foregroundStyle(.secondary) }
                Text(episode.name).font(.body.weight(.medium)).lineLimit(3)
                HStack(spacing: 5) {
                    if episode.locked { Image(systemName: "lock.fill").accessibilityLabel("Subscription required") }
                    if played { Image(systemName: "checkmark.circle.fill").accessibilityLabel("Played") }
                    Text(Date(timeIntervalSince1970: episode.published), format: .dateTime.day().month().year())
                    if episode.duration > 0 {
                        let minutes = Int(ceil((episode.duration - resumePosition) / 60))
                        if resumePosition > 0 { Text("· \(minutes) min left") }
                        else { Text("· \(minutes) min") }
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isCurrent { Image(systemName: "waveform").foregroundStyle(Color.accentColor) }
        }
        .opacity(played ? 0.72 : 1)
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

private extension EpisodeQuery.Filter {
    var title: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .unplayed: "Unplayed"
        case .played: "Played"
        }
    }
}
