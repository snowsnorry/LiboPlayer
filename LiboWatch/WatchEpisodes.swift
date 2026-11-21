import SwiftUI

struct EpisodeTitleStyle: ViewModifier {
    @ScaledMetric(relativeTo: .body) var size: CGFloat = 14
    func body(content: Content) -> some View { content.font(.system(size: size, weight: .regular)) }
}

extension View {
    func episodeTitle() -> some View {
        modifier(EpisodeTitleStyle())
    }
}

struct WatchEpisodeRows: View {
    let episodes: [Episode]
    let source: QueueSource
    var body: some View {
        ForEach(episodes) { episode in WatchEpisodeRow(episode: episode, source: source) }
    }
}

struct WatchEpisodeRow: View {
    let episode: Episode
    let source: QueueSource
    var fallbackShow: Show?
    @Environment(PodcastLibrary.self) private var library
    @Environment(PodcastPlayer.self) private var player
    @Environment(WatchDownloads.self) private var downloads
    @Environment(WatchNavigation.self) private var navigation
    private func openMenu() { navigation.path.append(.actions(episode)) }

    var body: some View {
        let show = library.show(for: episode) ?? fallbackShow
        Button {
            if episode.locked { openMenu() }
            else {
                if player.current?.id != episode.id || !player.playing { player.toggle(episode, from: source) }
                player.expanded = true
            }
        } label: {
            HStack(alignment: .top, spacing: 7) {
                WatchArt(address: WatchArtwork.address(episode.artwork, show?.artwork), size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    if let show, source != .downloaded { Text(show.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    Text(episode.name).episodeTitle().lineLimit(2)
                    HStack(spacing: 4) {
                        status
                        if library.collection.isSaved(episode.id) { Image(systemName: "bookmark.fill").accessibilityLabel("Saved") }
                        if player.isFinished(episode) { Image(systemName: "checkmark").accessibilityLabel("Played") }
                    }.font(.caption2).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("watch-episode")
        .accessibilityAction(named: "More") { openMenu() }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("More", systemImage: "ellipsis") { openMenu() }.tint(.purple)
        }
    }

    @ViewBuilder private var status: some View {
        if episode.locked { Label("Subscription required", systemImage: "lock.fill") }
        else if source == .downloaded, library.collection.localURL(episode.id) != nil {
            Label("On Watch", systemImage: "checkmark.circle.fill").foregroundStyle(.purple)
        } else if let request = downloads.requests.first(where: { $0.id == episode.id }) {
            if let failure = request.failure { Text(failure) }
            else if request.waitingForNetwork == true { Text("Waiting for network") }
            else if let fraction = library.collection.downloadsInProgress[episode.id]?.fractionCompleted {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
            } else { Text("Downloading…") }
        } else {
            Image(systemName: player.current?.id == episode.id && player.playing ? "waveform" : "play.fill")
            let after = player.playbackPosition(for: episode)
            if episode.duration > 0 {
                Text(Duration.seconds(max(0, episode.duration - after)), format: .units(allowed: [.hours, .minutes], width: .narrow))
            }
            if library.collection.localURL(episode.id) != nil { Image(systemName: "arrow.down.circle.fill").accessibilityLabel("Downloaded") }
        }
    }
}

struct WatchEpisodeActions: View {
    let episode: Episode
    @Environment(PodcastLibrary.self) private var library
    @Environment(PodcastPlayer.self) private var player
    @Environment(WatchDownloads.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemoval = false

    var body: some View {
        List {
            let played = player.isFinished(episode)
            Button(played ? "Mark as Unplayed" : "Mark as Played", systemImage: played ? "arrow.counterclockwise" : "checkmark.circle") {
                Task { await player.mark(episode, played: !played); dismiss() }
            }
            let saved = library.collection.isSaved(episode.id)
            Button(saved ? "Unsave" : "Save", systemImage: saved ? "bookmark.slash" : "bookmark") {
                library.setSaved(!saved, for: episode); dismiss()
            }
            if library.collection.localURL(episode.id) != nil {
                Button("Remove Download", systemImage: "trash", role: .destructive) { confirmRemoval = true }
            } else if let request = downloads.requests.first(where: { $0.id == episode.id }) {
                if !request.ready {
                    Button("Retry Download", systemImage: "arrow.clockwise") { downloads.enqueue(episode); dismiss() }
                }
                Button("Cancel Download", systemImage: "xmark.circle") { downloads.cancel(episode); dismiss() }
            } else {
                Button("Download", systemImage: "arrow.down.circle") { downloads.enqueue(episode); dismiss() }.disabled(episode.locked)
            }
            NavigationLink { WatchEpisodeDetails(episode: episode) } label: { Label("Episode Details", systemImage: "info.circle") }
            if episode.locked { NavigationLink { WatchAccount() } label: { Label("Account & Sync", systemImage: "lock.fill") } }
        }
        .navigationTitle("Episode actions")
        .confirmationDialog("Remove the audio file from this Apple Watch?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove from Watch", role: .destructive) {
                do { try library.collection.removeDownload(episode.id); dismiss() }
                catch { library.message = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct WatchEpisodeDetails: View {
    let episode: Episode
    @Environment(PodcastLibrary.self) private var library
    @State private var summary: String?

    var body: some View {
        let show = library.show(for: episode)
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack { WatchArt(address: WatchArtwork.address(episode.artwork, show?.artwork), size: 40); Text(show?.name ?? "").font(.caption) }
                Text(episode.name).episodeTitle()
                if episode.published > 0 { Text(Date(timeIntervalSince1970: episode.published), style: .date).font(.caption2) }
                if episode.locked { Label("Subscription required", systemImage: "lock.fill").font(.caption2) }
                if let summary { Text(summary).font(.footnote) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Episode")
        .task(id: episode.id) {
            var notes = episode.description
            if notes == nil { notes = try? await library.sessionForRequest().episodeDescription(episode.id) }
            guard !Task.isCancelled else { return }
            summary = notes?.replacingOccurrences(of: "(?i)<br */?>|</p>", with: "\n", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
        }
    }
}
