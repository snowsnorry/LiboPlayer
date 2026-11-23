import SwiftUI

struct EpisodeList: View {
    @Environment(PodcastPlayer.self) private var player
    let episodes: [Episode]
    let source: QueueSource
    @Binding var query: EpisodeQuery
    let openShow: ((Show) -> Void)?
    @State private var selectedEpisode: Episode?

    var body: some View {
        let results = query.results(in: episodes, isFinished: player.isFinished)
        List(results) { episode in
            EpisodeListRow(episode: episode, source: source, openShow: openShow) {
                selectedEpisode = episode
            }
        }
        .listStyle(.plain)
        .navigationDestination(item: $selectedEpisode) { episode in
            EpisodeDetails(episode: episode, source: source)
        }
        .overlay {
            if results.isEmpty {
                ContentUnavailableView("No Matching Episodes", systemImage: "magnifyingglass",
                                       description: Text("Try another title or listening status."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EpisodeFilterMenu(filter: $query.filter)
            }
        }
    }
}

struct EpisodeFilterMenu: View {
    @Binding var filter: EpisodeQuery.Filter

    var body: some View {
        Menu {
            Picker("Listening status", selection: $filter) {
                ForEach(EpisodeQuery.Filter.allCases, id: \.self) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.inline)
        } label: {
            let active = filter != .all
            Label("Filter episodes", systemImage: active
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly)
                .environment(\.symbolVariants, .none)
                .foregroundStyle(active ? Color.accentColor : .primary)
        }
        .accessibilityValue(Text(filter.title))
    }
}

struct EpisodeListRow: View {
    @Environment(PodcastLibrary.self) private var library
    @Environment(PodcastPlayer.self) private var player
    @Environment(\.dynamicTypeSize) private var typeSize
    let episode: Episode
    let source: QueueSource
    let openShow: ((Show) -> Void)?
    let openDetails: () -> Void
    private let rowInsets = EdgeInsets(top: 19, leading: 16, bottom: 19, trailing: 16)
    private let coverSize: CGFloat = 76
    private let spacing: CGFloat = 12

    var body: some View {
        let played = player.isFinished(episode)
        let started = played || player.history.resume(episode) > 0 || player.current?.id == episode.id
        let saved = library.collection.isSaved(episode.id)
        let downloaded = library.collection.localURL(episode.id) != nil
        let download = library.collection.downloadsInProgress[episode.id]
        let show = library.show(for: episode)
        Button(action: openDetails) {
            HStack(alignment: .top, spacing: spacing) {
                Cover(artwork: episode.artwork ?? show?.artwork, radius: 8)
                    .frame(width: coverSize)
                VStack(alignment: .leading, spacing: 4) {
                    metadata(openShow == nil ? nil : show, played: played)
                    Text(episode.name)
                        .font(.body.weight(started ? .regular : .semibold))
                        .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                        .foregroundStyle(played ? .secondary : .primary)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        if saved { Image(systemName: "bookmark.fill").accessibilityLabel(Text(LocalizedStringResource("episode.status.saved", defaultValue: "Saved"))) }
                        if let download { EpisodeDownloadRing(download: download) }
                        else if downloaded {
                            Image(systemName: "arrow.down.circle.fill").accessibilityLabel(Text(LocalizedStringResource("episode.status.downloaded", defaultValue: "Downloaded")))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                }
            }
            .padding(rowInsets)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Open episode details")
        .overlay(alignment: .bottomLeading) {
            EpisodePlaybackButton(episode: episode, source: source)
                .padding(.leading, coverSize + spacing)
                .padding(rowInsets)
        }
        .opacity(played ? 0.75 : 1)
        .contentShape(Rectangle())
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16))
        .contextMenu {
            ControlGroup {
                downloadButton(downloaded: downloaded, downloading: download != nil)
                saveButton(saved: saved)
                ShareLink(item: shareURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            Divider()
            playedButton(played: played)
            Divider()
            Button("Go to Episode", systemImage: "info.square", action: openDetails)
            if let openShow, let show {
                Button("Go to Show", systemImage: "dot.radiowaves.left.and.right") { openShow(show) }
            }
        }
        .swipeActions(edge: .leading) {
            playedButton(played: played).labelStyle(.iconOnly).tint(.purple)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            downloadButton(downloaded: downloaded, downloading: download != nil)
                .labelStyle(.iconOnly).tint(downloaded ? .red : .blue)
            saveButton(saved: saved).labelStyle(.iconOnly).tint(.yellow)
        }
        .listRowInsets(EdgeInsets())
    }

    private var shareURL: URL {
        StudioSite.home.appending(queryItems: [URLQueryItem(name: "start", value: "item_\(episode.id)")])
    }

    private func downloadButton(downloaded: Bool, downloading: Bool) -> some View {
        Button {
            Task { await library.toggleDownload(episode) }
        } label: {
            if downloaded { Label("Remove Download", systemImage: "trash") }
            else if downloading { Label("Downloading…", systemImage: "ellipsis.circle") }
            else { Label("Download", systemImage: "arrow.down.circle") }
        }
        .disabled(downloading || (!downloaded && episode.locked))
    }

    private func saveButton(saved: Bool) -> some View {
        let title: LocalizedStringKey = saved ? "Unsave" : "Save"
        return Button(title, systemImage: saved ? "bookmark.slash" : "bookmark") {
            library.setSaved(!saved, for: episode)
        }
    }

    private func playedButton(played: Bool) -> some View {
        let title: LocalizedStringKey = played ? "Mark as Unplayed" : "Mark as Played"
        return Button(title, systemImage: played ? "arrow.counterclockwise" : "checkmark") {
            Task { await player.mark(episode, played: !played) }
        }
        .disabled(library.busy || library.updatingPlayed.contains(episode.id))
    }

    private func metadata(_ show: Show?, played: Bool) -> some View {
        HStack(spacing: 5) {
            if played { Image(systemName: "checkmark").accessibilityLabel(Text(LocalizedStringResource("episode.status.played", defaultValue: "Played"))) }
            if episode.published > 0 {
                Text(Date(timeIntervalSince1970: episode.published), format: .dateTime.day().month().year())
                    .layoutPriority(1)
            }
            if let show {
                if episode.published > 0 { Text("·").accessibilityHidden(true) }
                Text(show.name).lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct EpisodePlaybackButton: View {
    @Environment(PodcastPlayer.self) private var player
    let episode: Episode
    let source: QueueSource

    var body: some View {
        let isCurrent = player.current?.id == episode.id
        let playing = isCurrent && player.playing
        let loading = isCurrent && player.loading
        let position = player.playbackPosition(for: episode)
        let duration = isCurrent && player.duration > 0 ? player.duration : episode.duration
        let hasDuration = duration.isFinite && duration > 0
        let hasProgress = hasDuration && position > 0 && position < duration
        let remainingTime = hasDuration ? Duration.seconds(max(1, ceil((duration - position) / 60)) * 60) : nil
        Button { player.toggle(episode, from: source) } label: {
            HStack(spacing: 6) {
                if loading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: icon(playing: playing))
                }
                if hasProgress {
                    ProgressView(value: position, total: duration)
                        .progressViewStyle(.linear)
                        .tint(.purple)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                }
                if let remainingTime {
                    Text(remainingTime, format: .units(allowed: [.hours, .minutes], width: .narrow))
                        .lineLimit(1)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(episode.locked ? Color.secondary : Color.purple)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loading || episode.locked)
        .accessibilityLabel(label(playing: playing, loading: loading))
        .accessibilityValue(timeLabel(remainingTime, hasProgress: hasProgress))
    }

    private func icon(playing: Bool) -> String {
        if episode.locked { return "lock.fill" }
        return playing ? "pause.fill" : "play.fill"
    }

    private func label(playing: Bool, loading: Bool) -> Text {
        if episode.locked { return Text("Subscription required") }
        if loading { return Text("Loading audio…") }
        return playing ? Text("Pause") : Text("Play")
    }

    private func timeLabel(_ remainingTime: Duration?, hasProgress: Bool) -> Text {
        guard let remainingTime else { return Text("") }
        let time = remainingTime.formatted(.units(allowed: [.hours, .minutes], width: .wide))
        return hasProgress ? Text("\(time) left") : Text(verbatim: time)
    }
}

private struct EpisodeDownloadRing: View {
    let download: EpisodeDownload

    var body: some View {
        Group {
            if let fraction = download.fractionCompleted {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 2)
                    Circle().trim(from: 0, to: fraction)
                        .stroke(.purple, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .frame(width: 15, height: 15)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Downloading…")
        .accessibilityValue(download.fractionCompleted.map {
            Text($0, format: .percent.precision(.fractionLength(0)))
        } ?? Text(""))
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
