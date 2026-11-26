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
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
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
    @ScaledMetric(relativeTo: .caption) private var playedMarkHeight: CGFloat = 11
    @ScaledMetric(relativeTo: .caption) private var statusHeight: CGFloat = 12
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var rowInsets: EdgeInsets {
        let horizontal: CGFloat = isPad ? 24 : 16
        let vertical: CGFloat = isPad ? 10 : 19
        return EdgeInsets(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal)
    }
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
                        if saved { statusIcon("bookmark.fill", height: statusHeight).accessibilityLabel(Text(LocalizedStringResource("episode.status.saved", defaultValue: "Saved"))) }
                        if let download { EpisodeDownloadRing(download: download) }
                        else if downloaded {
                            statusIcon("arrow.down.circle.fill", height: statusHeight).accessibilityLabel(Text(LocalizedStringResource("episode.status.downloaded", defaultValue: "Downloaded")))
                        }
                        if isPad { Color.clear.frame(width: 44, height: 1).accessibilityHidden(true) }
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
        .overlay(alignment: .bottomTrailing) {
            if isPad {
                Menu {
                    episodeActions
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: statusHeight, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel("More")
                .accessibilityValue(Text(verbatim: episode.name))
                .padding(rowInsets)
            }
        }
        .opacity(played ? 0.75 : 1)
        .contentShape(Rectangle())
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16))
        .contextMenu { episodeActions }
        .swipeActions(edge: .leading) {
            EpisodePlayedButton(episode: episode).labelStyle(.iconOnly).tint(.purple)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            EpisodeDownloadButton(episode: episode).labelStyle(.iconOnly)
            EpisodeSaveButton(episode: episode).labelStyle(.iconOnly)
        }
        .listRowInsets(EdgeInsets())
    }

    private var episodeActions: some View {
        EpisodeMenuActions(episode: episode, openDetails: openDetails, openShow: openShow)
    }

    private func statusIcon(_ name: String, height: CGFloat) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .fixedSize()
    }

    private func metadata(_ show: Show?, played: Bool) -> some View {
        HStack(spacing: 5) {
            if played { statusIcon("checkmark", height: playedMarkHeight).accessibilityLabel(Text(LocalizedStringResource("episode.status.played", defaultValue: "Played"))) }
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

struct EpisodeMenuActions: View {
    @Environment(PodcastLibrary.self) private var library
    let episode: Episode
    let openDetails: () -> Void
    let openShow: ((Show) -> Void)?

    var body: some View {
        ControlGroup {
            EpisodeDownloadButton(episode: episode)
            EpisodeSaveButton(episode: episode)
            ShareLink(item: StudioSite.home.appending(queryItems: [URLQueryItem(name: "start", value: "item_\(episode.id)")])) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        Divider()
        EpisodePlayedButton(episode: episode)
        Divider()
        Button("Go to Episode", systemImage: "info.square", action: openDetails)
        if let openShow, let show = library.show(for: episode) {
            Button("Go to Show", systemImage: "dot.radiowaves.left.and.right") { openShow(show) }
        }
    }
}

private struct EpisodePlayedButton: View {
    @Environment(PodcastLibrary.self) private var library
    @Environment(PodcastPlayer.self) private var player
    let episode: Episode

    var body: some View {
        let played = player.isFinished(episode)
        let title: LocalizedStringKey = played ? "Mark as Unplayed" : "Mark as Played"
        Button(title, systemImage: played ? "arrow.counterclockwise" : "checkmark") {
            Task { await player.mark(episode, played: !played) }
        }
        .disabled(library.busy || library.updatingPlayed.contains(episode.id))
    }
}

struct EpisodeSaveButton: View {
    @Environment(PodcastLibrary.self) private var library
    let episode: Episode

    var body: some View {
        let saved = library.collection.isSaved(episode.id)
        let title: LocalizedStringKey = saved ? "Unsave" : "Save"
        Button {
            library.setSaved(!saved, for: episode)
        } label: {
            Label(title, systemImage: saved ? "bookmark.slash" : "bookmark")
        }
        .tint(.yellow)
    }
}

struct EpisodeDownloadButton: View {
    @Environment(PodcastLibrary.self) private var library
    let episode: Episode

    var body: some View {
        let downloaded = library.collection.localURL(episode.id) != nil
        let downloading = library.collection.downloadsInProgress[episode.id] != nil
        Button {
            Task { await library.toggleDownload(episode) }
        } label: {
            if downloaded { Label("Remove Download", systemImage: "trash") }
            else if downloading { Label("Downloading…", systemImage: "ellipsis.circle") }
            else { Label("Download", systemImage: "arrow.down.circle") }
        }
        .disabled(downloading || (!downloaded && episode.locked))
        .tint(downloaded ? .red : .blue)
    }
}

struct EpisodePlaybackButton: View {
    @Environment(PodcastPlayer.self) private var player
    let episode: Episode
    let source: QueueSource
    var prominentHeight: CGFloat? = nil

    var body: some View {
        let isCurrent = player.current?.id == episode.id
        let playing = isCurrent && player.playing
        let loading = isCurrent && player.loading
        let position = player.playbackPosition(for: episode)
        let replay = player.isFinished(episode) && position == 0
        let duration = isCurrent && player.duration > 0 ? player.duration : episode.duration
        let hasDuration = duration.isFinite && duration > 0
        let hasProgress = hasDuration && position > 0 && position < duration
        let remainingTime = hasDuration ? Duration.seconds(max(1, ceil((duration - position) / 60)) * 60) : nil
        Button { player.toggle(episode, from: source) } label: {
            HStack(spacing: 6) {
                if loading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: icon(playing: playing, replay: replay))
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
            .font(prominentHeight == nil ? .subheadline.weight(.semibold) : .headline)
            .foregroundStyle(episode.locked ? Color.secondary : Color.purple)
            .padding(.horizontal, prominentHeight == nil ? 12 : 16)
            .padding(.vertical, 6)
            .frame(minWidth: prominentHeight, minHeight: prominentHeight)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loading || episode.locked)
        .accessibilityLabel(label(playing: playing, loading: loading, replay: replay))
        .accessibilityValue(timeLabel(remainingTime, hasProgress: hasProgress))
    }

    private func icon(playing: Bool, replay: Bool) -> String {
        if episode.locked { return "lock.fill" }
        if playing { return "pause.fill" }
        return replay ? "arrow.clockwise" : "play.fill"
    }

    private func label(playing: Bool, loading: Bool, replay: Bool) -> Text {
        if episode.locked { return Text("Subscription required") }
        if loading { return Text("Loading audio…") }
        if playing { return Text("Pause") }
        return replay ? Text("Replay") : Text("Play")
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
