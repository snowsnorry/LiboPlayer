import SwiftUI

@main @MainActor
struct LiboWatchApp: App {
    @State private var library: PodcastLibrary
    @State private var player: PodcastPlayer
    @State private var companion: CompanionSync
    @State private var downloads: WatchDownloads
    @Environment(\.scenePhase) private var phase

    init() {
        let library = PodcastLibrary()
        _downloads = State(initialValue: WatchDownloads(library: library))
        _library = State(initialValue: library)
        _player = State(initialValue: PodcastPlayer(library: library))
        _companion = State(initialValue: CompanionSync(library: library))
    }

    var body: some Scene {
        WindowGroup {
            WatchHome()
                .environment(library).environment(player).environment(companion).environment(downloads)
                .task(id: ObjectIdentifier(library.session)) {
                    if !library.ready { await library.refresh(quietIfCached: true) }
                }
                .task(id: phase == .active ? library.account : nil) {
                    if phase == .active { await player.refreshListeningWhileActive() }
                }
                .onChange(of: library.account) { _, account in player.useAccount(account); downloads.resume() }
                .onChange(of: phase) { _, phase in if phase == .active { downloads.resume(retryWaiting: true) } else { player.save() } }
        }
    }
}
