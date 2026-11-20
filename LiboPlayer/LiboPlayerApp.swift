import SwiftUI

@main
@MainActor
struct LiboPlayerApp: App {
    @State private var library: PodcastLibrary
    @State private var player: PodcastPlayer
    init() {
        let catalog = PodcastLibrary()
        _library = State(initialValue: catalog)
        _player = State(initialValue: PodcastPlayer(library: catalog))
    }
    var body: some Scene {
        WindowGroup {
            LibraryScreen().environment(library).environment(player)
        }
    }
}
