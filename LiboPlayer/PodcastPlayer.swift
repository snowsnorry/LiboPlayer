import AVFoundation
import MediaPlayer
import Observation

enum QueueSource { case library, show(String) }

@MainActor @Observable
final class PodcastPlayer {
    private let library: PodcastLibrary
    @ObservationIgnored private let engine = AVPlayer()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var tick: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var failureObserver: NSKeyValueObservation?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var lastSave: Double = 0
    private var owner = "guest"
    private var source = QueueSource.library
    private(set) var history = ListeningHistory()
    private(set) var current: Episode?
    private(set) var playing = false
    private(set) var loading = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var speed: Float = 1
    var expanded = false
    var message: String?

    init(library: PodcastLibrary) {
        self.library = library
        restoreHistory()
        tick = engine.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.updateClock() }
        }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            guard (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { self?.pause() }
        }
        installCommands()
    }

    func useAccount(_ id: String?) {
        let key = id.map { "account." + $0 } ?? "guest"
        guard owner != key else { return }
        save()
        clearItem()
        current = nil
        expanded = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        owner = key
        restoreHistory()
    }

    private var historyKey: String { "listening.v1." + owner }
    private func restoreHistory() {
        let data = UserDefaults.standard.data(forKey: historyKey)
        history = data.flatMap { try? JSONDecoder().decode(ListeningHistory.self, from: $0) } ?? ListeningHistory()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: historyKey) }
    }

    func isFinished(_ episode: Episode) -> Bool {
        history.isFinished(episode.id, serverPlayed: library.wasPlayed(episode))
    }

    func mark(_ episode: Episode, played: Bool) async {
        do {
            if library.account != nil {
                try await library.updatePlayed(played, for: episode)
                history.clearLocalStatus(episode.id)
            } else if played {
                history.finish(episode.id)
            } else {
                history.markUnplayed(episode.id)
            }
            if current?.id == episode.id {
                clearItem()
                position = played ? duration : 0
                publishNowPlaying()
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            persist()
        } catch is CancellationError {
            return
        } catch {
            message = String(localized: "Couldn’t update the listening status. Try again.")
        }
    }

    func save() {
        guard let current, !loading, engine.currentItem != nil, !isFinished(current) else { return }
        let seconds = engine.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return }
        history.positions[current.id] = seconds
        lastSave = seconds
        persist()
    }

    func select(_ episode: Episode, from source: QueueSource) {
        guard !episode.locked else { message = LibraryError.locked.errorDescription; return }
        self.source = source
        expanded = true
        if current?.id == episode.id && (loading || engine.currentItem != nil) {
            if !playing && !loading { resume() }
            return
        }
        start(episode)
    }

    private func start(_ episode: Episode) {
        save()
        clearItem()
        current = episode
        duration = episode.duration
        position = isFinished(episode) ? 0 : history.resume(episode)
        lastSave = position
        loading = true
        loadTask = Task {
            do {
                let url = try await library.session.stream(for: episode)
                try Task.checkCancellation()
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.playback, mode: .spokenAudio)
                try audio.setActive(true)
                let item = AVPlayerItem(url: url)
                engine.replaceCurrentItem(with: item)
                observe(item)
                if position > 0 {
                    _ = await item.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                                        toleranceBefore: .zero, toleranceAfter: .zero)
                }
                try Task.checkCancellation()
                loading = false
                resume()
            } catch {
                guard !Task.isCancelled else { return }
                loading = false
                message = String(localized: "Couldn’t start this episode. Try again.")
            }
        }
    }

    private func observe(_ item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item, queue: .main) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.engine.currentItem === item else { return }
                self.didFinish()
            }
        }
        failureObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                guard let self, self.engine.currentItem === item else { return }
                self.clearItem()
                self.message = String(localized: "Couldn’t play the audio. Check your connection and try again.")
            }
        }
    }

    private func didFinish() {
        guard let current else { return }
        history.finish(current.id)
        persist()
        clearItem() // Detach the finished item before starting its successor or saving progress.
        position = duration
        publishNowPlaying()
        // A newly followed show's archive may still be arriving when playback ends.
        loadTask = Task {
            do {
                let ordered: [Episode]
                switch source {
                case .library:
                    if !library.archiveReady { try await library.loadArchive() }
                    ordered = library.feed
                case .show(let id):
                    if let show = library.shows.first(where: { $0.id == id }) { try await library.load(show) }
                    ordered = library.episodes[id] ?? []
                }
                try Task.checkCancellation()
                if let next = Episode.next(after: current, in: ordered, finished: isFinished) {
                    start(next)
                } else {
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
            } catch {
                if !Task.isCancelled { message = String(localized: "Couldn’t load the next episode.") }
            }
        }
    }

    private func clearItem() {
        loadTask?.cancel()
        loadTask = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        failureObserver = nil
        engine.pause()
        engine.replaceCurrentItem(with: nil)
        playing = false
        loading = false
    }

    func toggle() {
        if playing { pause() } else { resume() }
    }

    private func resume() {
        guard let current, !loading else { return }
        guard engine.currentItem != nil else { start(current); return }
        engine.playImmediately(atRate: speed)
        playing = true
        publishNowPlaying()
    }

    private func pause() {
        engine.pause()
        playing = false
        save()
        publishNowPlaying()
    }

    func seek(_ seconds: Double) {
        guard !loading, let item = engine.currentItem, seconds.isFinite else { return }
        position = min(max(0, seconds), max(duration, 0))
        let target = CMTime(seconds: position, preferredTimescale: 600)
        engine.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard finished, let self, self.engine.currentItem === item else { return }
                self.save()
                self.publishNowPlaying()
            }
        }
    }

    func setSpeed(_ value: Float) {
        speed = value
        if playing { engine.rate = value }
        publishNowPlaying()
    }

    private func updateClock() {
        guard !loading, let item = engine.currentItem else { return }
        let seconds = item.currentTime().seconds
        if item.duration.seconds.isFinite { duration = item.duration.seconds }
        if seconds.isFinite {
            position = seconds
            if abs(seconds - lastSave) >= 5 { save() }
        }
    }

    private func publishNowPlaying() {
        guard let current else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.name,
            MPMediaItemPropertyArtist: library.shows.first { $0.id == current.showID }?.name ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? speed : 0
        ]
    }

    private func installCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        commands.skipBackwardCommand.preferredIntervals = [15]
        commands.skipForwardCommand.preferredIntervals = [30]
        for (command, offset) in [(commands.skipBackwardCommand, -15.0), (commands.skipForwardCommand, 30.0)] {
            command.addTarget { [weak self] _ in
                Task { @MainActor in if let self { self.seek(self.position + offset) } }
                return .success
            }
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor in self?.seek(seconds) }
            return .success
        }
    }
}
