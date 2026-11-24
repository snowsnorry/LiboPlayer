import SwiftUI
import WatchKit

struct WatchPlayer: View {
    @Environment(PodcastPlayer.self) private var player
    @Environment(PodcastLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingOptions = false

    private var volumeFocused: Bool {
        scenePhase == .active && !showingOptions && player.current != nil
            && player.message == nil && library.message == nil
    }

    var body: some View {
        NavigationStack {
            if let episode = player.current {
                let art = WatchArtwork.address(episode.artwork, library.show(for: episode)?.artwork)
                WatchPlaybackFace(episode: episode, art: art)
                    .background { backdrop(art).ignoresSafeArea() }
                    .background {
                        // Keep the system control in the focus hierarchy, behind the opaque artwork backdrop.
                        LocalVolumeControl(focused: volumeFocused)
                            .frame(width: 32, height: 32)
                            .accessibilityLabel("Volume")
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close", systemImage: "xmark") { player.expanded = false }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("More", systemImage: "ellipsis") { showingOptions = true }
                        }
                    }
                    .navigationDestination(isPresented: $showingOptions) {
                        WatchPlaybackOptions(episode: episode)
                    }
            }
        }
        .modifier(WatchVolumeOverlay(active: volumeFocused))
    }

    private func backdrop(_ art: String?) -> some View {
        GeometryReader { space in
            ZStack {
                Color(white: 0.22)
                WatchArtworkImage(address: art) { Color.clear }
                    .frame(width: space.size.width, height: space.size.height)
                    .clipped()
                    .blur(radius: 24)
                LinearGradient(colors: [.black.opacity(0.28), .black.opacity(0.52)],
                               startPoint: .top, endPoint: .bottom)
            }
            .clipped()
        }
        .accessibilityHidden(true)
    }
}

private struct WatchPlaybackFace: View {
    let episode: Episode
    let art: String?
    @Environment(PodcastPlayer.self) private var player
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { face in
            let playSize = min(54, max(42, face.size.width * 0.24))
            VStack(spacing: 4) {
                GeometryReader { space in
                    let side = min(space.size.width * 0.5, space.size.height)
                    WatchArt(address: art, size: side)
                        .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                VStack(spacing: 1) {
                    Text(episode.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                        .multilineTextAlignment(.center)
                    Text("\(Duration.seconds(max(0, player.duration - player.position)).formatted(.time(pattern: .minuteSecond))) left")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.76))
                        .lineLimit(1)
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 0) {
                    transport("Skip back 15 seconds", "gobackward.15", size: playSize * 0.76) {
                        player.seek(player.position - 15)
                    }
                    if player.loading {
                        ProgressView()
                            .frame(width: playSize, height: playSize)
                            .modifier(TransportCircle(primary: true))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    } else {
                        transport(player.playing ? "Pause" : "Play", player.playing ? "pause.fill" : "play.fill",
                                  size: playSize, primary: true) { player.toggle() }
                    }
                    transport("Skip forward 30 seconds", "goforward.30", size: playSize * 0.76) {
                        player.seek(player.position + 30)
                    }
                }
                .frame(height: max(44, playSize))
                .disabled(player.loading)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The square cover fits between the toolbar buttons, just below the clock.
            .padding(.top, face.size.height * 0.19)
            .padding(.bottom, face.size.height * 0.045)
        }
        .ignoresSafeArea(.container, edges: .vertical)
    }

    private func transport(_ name: LocalizedStringKey, _ icon: String, size: CGFloat,
                           primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * (primary ? 0.45 : 0.60), weight: .semibold))
                .frame(width: size, height: size)
                .modifier(TransportCircle(primary: primary))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}

private struct TransportCircle: ViewModifier {
    let primary: Bool

    func body(content: Content) -> some View {
        content
            .background(.white.opacity(primary ? 0.22 : 0.11), in: Circle())
            .overlay {
                Circle().strokeBorder(.white.opacity(primary ? 0.62 : 0.30), lineWidth: primary ? 1.4 : 0.7)
            }
    }
}

private struct WatchPlaybackOptions: View {
    let episode: Episode
    @Environment(PodcastPlayer.self) private var player
    @State private var outputs = false

    var body: some View {
        List {
            Picker("Speed", selection: Binding(get: { player.speed }, set: player.setSpeed)) {
                ForEach([0.75, 1, 1.25, 1.5, 1.75, 2] as [Float], id: \.self) { value in
                    Text("\(value.formatted())×").tag(value)
                }
            }
            NavigationLink {
                WatchPositionEditor()
            } label: { Label("Position", systemImage: "clock") }
            .disabled(player.duration <= 0 || player.loading)
            Button("Audio Output", systemImage: "airplayaudio") { outputs = true }
            NavigationLink {
                WatchEpisodeActions(episode: episode)
            } label: { Label("Episode actions", systemImage: "ellipsis") }
        }
        .navigationTitle("More")
        .sheet(isPresented: $outputs) { NowPlayingView() }
    }
}

private struct WatchPositionEditor: View {
    @Environment(PodcastPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var position: Double = 0

    var body: some View {
        VStack {
            Text(Duration.seconds(position), format: .time(pattern: .minuteSecond)).monospacedDigit()
            Slider(value: $position, in: 0...max(1, player.duration))
                .accessibilityLabel("Playback position")
            Button("Done") {
                player.seek(position)
                dismiss()
            }
        }
        .padding(.horizontal)
        .navigationTitle("Position")
        .onAppear { position = player.position }
    }
}
