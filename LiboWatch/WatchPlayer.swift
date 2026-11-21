import SwiftUI
import WatchKit

struct WatchPlayer: View {
    @Environment(PodcastPlayer.self) private var player
    @Environment(PodcastLibrary.self) private var library
    @State private var tab = 0
    @State private var outputs = false
    @State private var positionEditor = false
    @State private var seekPosition: Double = 0

    var body: some View {
        NavigationStack {
            if let episode = player.current {
                TabView(selection: $tab) {
                    controls(episode).tag(0)
                    List {
                        Picker("Speed", selection: Binding(get: { player.speed }, set: player.setSpeed)) {
                            ForEach([0.75, 1, 1.25, 1.5, 1.75, 2] as [Float], id: \.self) { value in
                                Text("\(value.formatted())×").tag(value)
                            }
                        }
                        Button("Position", systemImage: "clock") {
                            seekPosition = player.position
                            positionEditor = true
                        }.disabled(player.duration <= 0 || player.loading)
                        Button("Audio Output", systemImage: "airplayaudio") { outputs = true }
                        NavigationLink {
                            WatchEpisodeActions(episode: episode)
                        } label: { Label("Episode actions", systemImage: "ellipsis") }
                    }.containerBackground(.black.gradient, for: .tabView).tag(1)
                }
                .tabViewStyle(.verticalPage)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { player.expanded = false }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Audio Output", systemImage: "airplayaudio") { outputs = true }
                    }
                }
                .sheet(isPresented: $outputs) { NowPlayingView() }
                .sheet(isPresented: $positionEditor) {
                    VStack {
                        Text("Position").font(.headline)
                        Text(Duration.seconds(seekPosition), format: .time(pattern: .minuteSecond)).monospacedDigit()
                        Slider(value: $seekPosition, in: 0...max(1, player.duration))
                            .accessibilityLabel("Playback position")
                        Button("Done") { player.seek(seekPosition); positionEditor = false }
                    }.padding(.horizontal)
                }
            }
        }
    }

    private func controls(_ episode: Episode) -> some View {
        let art = WatchArtwork.address(episode.artwork, library.show(for: episode)?.artwork)
        return GeometryReader { geometry in
            VStack(spacing: 4) {
                WatchArt(address: art, size: min(78, max(30, geometry.size.height * 0.28)))
                Text(episode.name).episodeTitle().lineLimit(2).multilineTextAlignment(.center)
                Text("\(Duration.seconds(max(0, player.duration - player.position)).formatted(.time(pattern: .minuteSecond))) left")
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                HStack {
                    transport("Skip back 15 seconds", "gobackward.15") { player.seek(player.position - 15) }
                    if player.loading { ProgressView().frame(maxWidth: .infinity) }
                    else {
                        transport(player.playing ? "Pause" : "Play", player.playing ? "pause.fill" : "play.fill") { player.toggle() }
                    }
                    transport("Skip forward 30 seconds", "goforward.30") { player.seek(player.position + 30) }
                }.disabled(player.loading)
                LocalVolumeControl(focused: tab == 0 && !outputs && !positionEditor)
                    .frame(height: 17)
                    .accessibilityLabel("Volume")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .containerBackground(for: .tabView) {
            ZStack {
                Color.black
                WatchArtworkImage(address: art) { Color.clear }.blur(radius: 28).opacity(0.38)
            }
        }
    }

    private func transport(_ name: LocalizedStringKey, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3).frame(maxWidth: .infinity, minHeight: 40)
        }.buttonStyle(.borderless).accessibilityLabel(name)
    }
}

/// Route crown input to the watch's system volume. A vertical swipe still opens playback options.
private struct LocalVolumeControl: WKInterfaceObjectRepresentable {
    let focused: Bool

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        WKInterfaceVolumeControl(origin: .local)
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
        if focused { control.focus() } else { control.resignFocus() }
    }
}
