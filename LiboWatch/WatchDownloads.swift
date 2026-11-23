import Foundation
import Network
import Observation
import SwiftUI

/// User requests survive suspension and relaunch, independently of the paired phone.
@MainActor @Observable
final class WatchDownloads {
    // The raw values also decode failures saved by earlier releases.
    enum Failure: String, Codable {
        case storageFull = "Watch storage full"
        case downloadFailed = "Download failed"

        var label: LocalizedStringKey {
            switch self {
            case .storageFull: "Watch storage full"
            case .downloadFailed: "Download failed"
            }
        }
    }

    struct Request: Codable, Identifiable {
        let episode: Episode
        let show: Show?
        var failure: Failure?
        var waitingForNetwork: Bool?
        var ready: Bool { failure == nil && waitingForNetwork != true }
        var id: String { episode.id }
    }

    private let library: PodcastLibrary
    private var owner: String?
    private(set) var requests: [Request] = []
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(library: PodcastLibrary) {
        self.library = library
        owner = library.account
        restore()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                if path.status == .satisfied { self.resume(retryWaiting: true) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.liboplayer.watch.downloads"))
    }

    private var key: String { "watch.download.requests." + (owner.map { "account." + $0 } ?? "guest") }

    func resume(retryWaiting: Bool = false) {
        if owner != library.account {
            generation = UUID()
            worker?.cancel(); worker = nil
            owner = library.account
            restore()
        }
        if retryWaiting {
            for i in requests.indices where requests[i].waitingForNetwork == true {
                requests[i].waitingForNetwork = false
            }
        }
        guard worker == nil, requests.contains(where: \.ready) else { return }
        let active = generation
        worker = Task { await run(generation: active) }
    }

    func enqueue(_ episode: Episode) {
        guard !episode.locked else { return }
        resume()
        if let index = requests.firstIndex(where: { $0.id == episode.id }) {
            requests[index].failure = nil
            requests[index].waitingForNetwork = false
        } else {
            requests.append(Request(episode: episode.offlineMetadata, show: library.show(for: episode)))
        }
        persist()
        resume()
    }

    func cancel(_ episode: Episode) {
        if requests.first(where: \.ready)?.id == episode.id {
            generation = UUID()
            worker?.cancel(); worker = nil
        }
        requests.removeAll { $0.id == episode.id }
        persist()
        resume()
    }

    private func restore() {
        requests = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([Request].self, from: $0) } ?? []
        requests.removeAll { library.collection.localURL($0.id) != nil }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(requests) { UserDefaults.standard.set(data, forKey: key) }
    }

    private func run(generation active: UUID) async {
        defer { if active == generation { worker = nil } }
        while let request = requests.first(where: \.ready) {
            let shelf = library.collection
            do {
                try await library.download(request.episode, to: shelf)
                try Task.checkCancellation()
                guard active == generation, shelf === library.collection else { return }
                if shelf.localURL(request.id) == nil {
                    // A cancelled predecessor is still releasing the download slot.
                    try await Task.sleep(for: .milliseconds(250))
                    continue
                }
                requests.removeAll { $0.id == request.id }
            } catch {
                guard active == generation, !Task.isCancelled, shelf === library.collection else { return }
                if let index = requests.firstIndex(where: { $0.id == request.id }) {
                    let failure = error as NSError
                    if let network = error as? URLError, [.notConnectedToInternet, .networkConnectionLost].contains(network.code) {
                        requests[index].waitingForNetwork = true
                    } else if failure.domain == NSCocoaErrorDomain && failure.code == NSFileWriteOutOfSpaceError {
                        requests[index].failure = .storageFull
                    } else {
                        requests[index].failure = .downloadFailed
                    }
                }
            }
            persist()
        }
    }
}

struct WatchDownloaded: View {
    @Environment(PodcastLibrary.self) private var library
    @Environment(WatchDownloads.self) private var downloads
    var body: some View {
        List {
            WatchEpisodeRows(episodes: library.collection.downloaded, source: .downloaded)
            ForEach(downloads.requests.filter { library.collection.localURL($0.id) == nil }) { request in
                WatchEpisodeRow(episode: request.episode, source: .downloaded, fallbackShow: request.show)
            }
        }
        .overlay {
            if library.collection.downloaded.isEmpty && downloads.requests.isEmpty {
                ContentUnavailableView {
                    Label("No Downloaded Episodes", systemImage: "arrow.down.circle")
                } description: { Text("Swipe left on an episode, tap More, then Download.") }
            }
        }
        .navigationTitle("Downloaded")
    }
}
