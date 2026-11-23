import SwiftUI

enum WatchRoute: Hashable {
    case allShows, library, search, following, show(Show)
    case saved, downloaded, latest, account
    case actions(Episode)
}

@Observable @MainActor
final class WatchNavigation {
    var path = [WatchRoute]()
}

struct WatchHome: View {
    @Environment(PodcastLibrary.self) private var library
    @Environment(PodcastPlayer.self) private var player
    @State private var navigation = WatchNavigation()

    var body: some View {
        @Bindable var player = player
        @Bindable var navigation = navigation
        NavigationStack(path: $navigation.path) {
            List {
                link("Account & Sync", "person.crop.circle", .account)
                link("All Shows", "square.grid.2x2", .allShows)
                link("Library", "rectangle.stack", .library)
                link("Search", "magnifyingglass", .search)
            }
            .navigationTitle("Libo Player")
            .modifier(PlayerShortcut())
            .navigationDestination(for: WatchRoute.self) { route in
                destination(route).modifier(PlayerShortcut())
            }
        }
        .environment(navigation)
        .tint(.accentColor)
        .onChange(of: library.account) {
            navigation.path = navigation.path.last == .account ? [.account] : []
        }
        .sheet(isPresented: $player.expanded) { WatchPlayer().modifier(WatchAlerts()) }
        .modifier(WatchAlerts())
    }

    private func link(_ title: LocalizedStringKey, _ symbol: String, _ route: WatchRoute) -> some View {
        NavigationLink(value: route) {
            Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(Color.accentColor) }
        }
    }

    @ViewBuilder private func destination(_ route: WatchRoute) -> some View {
        switch route {
        case .allShows, .following, .latest, .show:
            WatchCatalog(route: route)
        case .library:
            List {
                link("Following", "heart", .following)
                link("Saved", "bookmark", .saved)
                link("Downloaded", "arrow.down.circle", .downloaded)
                link("Latest Episodes", "clock", .latest)
            }.navigationTitle("Library")
        case .saved:
            List { WatchEpisodeRows(episodes: library.collection.saved, source: .saved) }
                .overlay { if library.collection.saved.isEmpty { WatchEmptySaved() } }
                .navigationTitle("Saved")
        case .downloaded:
            WatchDownloaded()
        case .search:
            WatchSearch()
        case .account:
            WatchAccount()
        case .actions(let episode):
            WatchEpisodeActions(episode: episode)
        }
    }
}

struct WatchAlerts: ViewModifier {
    @Environment(PodcastLibrary.self) var library
    @Environment(PodcastPlayer.self) var player
    func body(content: Content) -> some View {
        content.alert("Libo Player", isPresented: Binding(get: { library.message != nil || player.message != nil },
            set: { if !$0 { library.message = nil; player.message = nil } })) {
            Button("Close", role: .cancel) {}
        } message: { Text(player.message ?? library.message ?? "") }
    }
}

private struct PlayerShortcut: ViewModifier {
    @Environment(PodcastPlayer.self) var player
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if player.current != nil {
                    Button {
                        player.expanded = true
                    } label: {
                        Image(systemName: "waveform")
                            .symbolRenderingMode(.monochrome)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .tint(Color(white: 0.18))
                    .accessibilityLabel("Now Playing")
                }
            }
        }
    }
}

private struct WatchEmptySaved: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Saved Episodes", systemImage: "bookmark")
        } description: { Text("Swipe left on an episode, tap More, then Save.") }
        actions: { NavigationLink("Browse Shows", value: WatchRoute.allShows) }
    }
}

struct WatchAccount: View {
    @Environment(PodcastLibrary.self) private var library
    @Environment(CompanionSync.self) private var companion

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()

    var body: some View {
        List {
            if library.account != nil {
                Label("Connected", systemImage: "checkmark.circle")
            } else {
                Text("To connect your account, sign in to Libo Player on your paired iPhone. You can also browse as a guest.")
            }
            if let date = companion.lastReceived {
                let timestamp = Text(verbatim: Self.timestampFormatter.string(from: date))
                timestamp
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel("Bookmark sync")
                    .accessibilityValue(timestamp)
            }
            Button { companion.synchronize() } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    if let statusText { Text(statusText).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .disabled(companion.status == .contacting)
            if let issue = companion.issue { Text(issue).font(.footnote) }
        }.navigationTitle("Account & Sync")
    }

    private var statusText: LocalizedStringKey? {
        switch companion.status {
        case .idle: nil
        case .contacting: "Contacting iPhone…"
        case .waiting: "Waiting for iPhone. Open Libo Player on your phone."
        case .unlockPhone: "Unlock your iPhone after restart, then open Libo Player."
        case .installPhoneApp: "Install Libo Player on your iPhone."
        case .signIn: "iPhone is in guest mode. Sign in on your phone."
        case .complete: "Account received from iPhone."
        case .failed: "No account received. Open the updated iPhone app and try again."
        }
    }
}

struct WatchArt: View {
    let address: String?
    let size: CGFloat
    var body: some View {
        WatchArtworkImage(address: address) {
            ZStack { Color.gray.opacity(0.24); Image(systemName: "waveform").foregroundStyle(.secondary) }
        }
        .frame(width: size, height: size).clipShape(.rect(cornerRadius: size * 0.14))
        .accessibilityHidden(true)
    }
}

struct WatchShowRow: View {
    let show: Show
    var body: some View {
        NavigationLink(value: WatchRoute.show(show)) {
            HStack {
                WatchArt(address: show.artwork, size: 34)
                Text(show.name).lineLimit(2)
            }
        }.accessibilityIdentifier("watch-show")
    }
}
