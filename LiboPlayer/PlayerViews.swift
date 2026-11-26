import SwiftUI

@available(iOS 26.0, *)
struct MiniPlayerAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        MiniPlayer(inline: placement == .inline)
    }
}

struct MiniPlayer: View {
    @Environment(PodcastPlayer.self) private var player
    @Environment(PodcastLibrary.self) private var library
    let inline: Bool

    var body: some View {
        if let item = player.current {
            let show = library.show(for: item)
            HStack(spacing: inline ? 0 : 4) {
                Button { player.expanded = true } label: {
                    HStack(spacing: 8) {
                        Cover(artwork: item.artwork ?? show?.artwork, radius: 6)
                            .frame(width: inline ? 28 : 32, height: inline ? 28 : 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if let show {
                                Text(show.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityHint("Open player")
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel(player.playing ? Text("Pause") : Text("Play"))
                    .disabled(player.loading)
                if !inline {
                    Button { player.seek(player.position + 30) } label: {
                        Image(systemName: "goforward.30").frame(width: 44, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel("Skip forward 30 seconds")
                        .disabled(player.loading)
                }
            }
            .padding(.leading, inline ? 8 : 16)
            .padding(.trailing, inline ? 2 : 8)
        }
    }
}

struct PlayerSheet: View {
    @Environment(PodcastPlayer.self) private var player
    @Environment(PodcastLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var dragging: Double?
    var body: some View {
        if let item = player.current {
            let show = library.show(for: item)
            ViewThatFits(in: .vertical) {
                contents(item, show, large: true)
                ScrollView { contents(item, show, large: false) }
            }.padding(.horizontal, 28).padding(.vertical, 22)
        }
    }

    private func contents(_ item: Episode, _ show: Show?, large: Bool) -> some View {
        VStack(alignment: .leading, spacing: large ? 22 : 12) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                    .accessibilityLabel("Minimize player")
                Spacer()
                PlaybackSpeedMenu()
            }
            Cover(artwork: item.artwork ?? show?.artwork, radius: 18)
                .frame(maxHeight: large ? 360 : 190).frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.name).font(.title2.bold())
                Text(show?.name ?? "").foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                Slider(value: Binding(get: { min(dragging ?? player.position, max(1, player.duration)) },
                                      set: { dragging = $0 }), in: 0...max(1, player.duration)) { editing in
                    if !editing, let target = dragging { player.seek(target); dragging = nil }
                }.disabled(player.loading || player.duration <= 0)
                .accessibilityLabel("Playback position")
                HStack {
                    Text(clock(dragging ?? player.position))
                    Spacer()
                    Text("−" + clock(max(0, player.duration - (dragging ?? player.position))))
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 36) {
                Button { player.seek(player.position - 15) } label: { Image(systemName: "gobackward.15").font(.title) }
                    .accessibilityLabel("Skip back 15 seconds")
                Button { player.toggle() } label: {
                    if player.loading { ProgressView().frame(width: 52, height: 58) }
                    else { Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 44)).frame(width: 52, height: 58) }
                }.accessibilityLabel(player.playing ? Text("Pause") : Text("Play"))
                Button { player.seek(player.position + 30) } label: { Image(systemName: "goforward.30").font(.title) }
                    .accessibilityLabel("Skip forward 30 seconds")
            }.frame(maxWidth: .infinity).disabled(player.loading)
        }
        .foregroundStyle(.primary)
        .onChange(of: item.id) { dragging = nil }
    }

    private func clock(_ seconds: Double) -> String {
        Duration.seconds(Int(max(0, seconds))).formatted(.time(pattern: .minuteSecond))
    }
}

private struct PlaybackSpeedMenu: View {
    @Environment(PodcastPlayer.self) private var player

    var body: some View {
        Menu {
            Picker("Playback speed", selection: Binding(get: { player.speed }, set: player.setSpeed)) {
                ForEach([Float(0.75), 1, 1.25, 1.5, 1.75, 2], id: \.self) { rate in
                    Text(verbatim: "\(rate.formatted())×").tag(rate)
                }
            }
        } label: {
            Text(verbatim: "\(player.speed.formatted())×").font(.headline.monospacedDigit())
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Playback speed")
        .accessibilityValue(Text(verbatim: "\(player.speed.formatted())×"))
    }
}

struct PadMiniPlayer: View {
    @Environment(PodcastPlayer.self) private var player
    @Environment(PodcastLibrary.self) private var library
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    let episode: Episode
    let openDetails: () -> Void
    let openShow: (Show) -> Void

    var body: some View {
        let narrow = sizeClass == .compact || typeSize.isAccessibilitySize
        let shape = RoundedRectangle(cornerRadius: narrow ? 24 : 36, style: .continuous)
        let bar = Group {
            if narrow {
                VStack(spacing: 0) {
                    HStack { nowPlaying; episodeMenu }
                    transport
                }
            } else {
                HStack(spacing: 14) {
                    transport
                    nowPlaying
                    episodeMenu
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        Group {
            if #available(iOS 26, *) {
                bar.glassEffect(.regular, in: shape)
            } else {
                bar.background(.regularMaterial, in: shape)
            }
        }
        .frame(maxWidth: 1000)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var transport: some View {
        HStack(spacing: 4) {
            PlaybackSpeedMenu()
            Button { player.seek(player.position - 15) } label: {
                Image(systemName: "gobackward.15").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Skip back 15 seconds")
            Button { player.toggle() } label: {
                Group {
                    if player.loading { ProgressView() }
                    else { Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title) }
                }.frame(width: 44, height: 44)
            }
            .accessibilityLabel(player.playing ? Text("Pause") : Text("Play"))
            Button { player.seek(player.position + 30) } label: {
                Image(systemName: "goforward.30").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Skip forward 30 seconds")
        }
        .font(.title2)
        .disabled(player.loading)
    }

    private var nowPlaying: some View {
        let show = library.show(for: episode)
        return Button { player.expanded = true } label: {
            HStack(spacing: 10) {
                Cover(artwork: episode.artwork ?? show?.artwork, radius: 6).frame(width: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(episode.name).font(.headline).lineLimit(1)
                    if let show { Text(show.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .accessibilityHint("Open player")
    }

    private var episodeMenu: some View {
        Menu {
            EpisodeMenuActions(episode: episode, openDetails: openDetails, openShow: openShow)
        } label: {
            Image(systemName: "ellipsis").font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("More")
        .accessibilityValue(Text(verbatim: episode.name))
    }
}
