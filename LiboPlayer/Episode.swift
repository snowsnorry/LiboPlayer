import Foundation

struct Show: Codable, Identifiable, Hashable {
    let id, name: String
    let artwork: String?
    var lastEpisode: Double? = nil

    static func recentlyUpdated(_ followed: [Self], archives: [String: [Episode]]) -> [Self] {
        followed.compactMap { show -> Self? in
            var result = show
            if let episodes = archives[show.id] {
                // PodcastLibrary stores each archive newest first, in the same order as Latest Episodes.
                result.lastEpisode = episodes.first?.published
            }
            guard let date = result.lastEpisode, date > 0 else { return nil }
            return result
        }.sorted { lhs, rhs in
            if lhs.lastEpisode == rhs.lastEpisode { return alphabetical(lhs, rhs) }
            return (lhs.lastEpisode ?? 0) > (rhs.lastEpisode ?? 0)
        }
    }

    static func alphabetical(_ lhs: Self, _ rhs: Self) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }
}

struct StudioCategory: Hashable, Identifiable {
    let id, name: String
}

struct Episode: Codable, Identifiable, Hashable {
    let id, showID, name: String
    let published, duration: Double
    var locked: Bool
    let played: Bool
    let artwork: String?
    var track: String?
    var access: Access? = nil
    enum Access: String, Codable { case subscription, guide }

    var offlineMetadata: Self {
        var copy = self
        copy.track = nil
        return copy
    }

    var streamURL: URL? {
        guard let track, let url = URL(string: track), url.scheme == "https" else { return nil }
        return url
    }

    static func precedes(_ a: Self, _ b: Self) -> Bool {
        a.published == b.published ? a.id < b.id : a.published > b.published
    }

    static func next(after current: Self, in ordered: [Self], finished: (Self) -> Bool) -> Self? {
        ordered.first { $0.id != current.id && precedes(current, $0) && !$0.locked && !finished($0) }
    }
}

struct ListeningHistory: Codable {
    var positions: [String: Double] = [:]
    var completed: Set<String> = []
    // Older histories contain only positions and completed IDs.
    private var unplayed: Set<String>?

    init() {}

    func isFinished(_ id: String, serverPlayed: Bool) -> Bool {
        if unplayed?.contains(id) == true { return false }
        return completed.contains(id) || serverPlayed
    }

    func resume(_ episode: Episode) -> Double {
        let value = positions[episode.id] ?? 0
        return value.isFinite && value > 0 && (episode.duration <= 0 || value < episode.duration) ? value : 0
    }

    mutating func finish(_ id: String) {
        unplayed?.remove(id)
        completed.insert(id)
        positions.removeValue(forKey: id)
    }

    mutating func markUnplayed(_ id: String) {
        clearLocalStatus(id)
        if unplayed == nil { unplayed = [] }
        unplayed?.insert(id)
    }

    mutating func clearLocalStatus(_ id: String) {
        completed.remove(id)
        unplayed?.remove(id)
        positions.removeValue(forKey: id)
    }
}

struct EpisodeQuery {
    enum Filter: CaseIterable { case all, unplayed, played }
    var title = ""
    var filter = Filter.all

    func results(in episodes: [Episode], isFinished: (Episode) -> Bool) -> [Episode] {
        let term = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if filter == .all && term.isEmpty { return episodes }
        return episodes.filter { episode in
            guard term.isEmpty || episode.name.localizedStandardContains(term) else { return false }
            switch filter {
            case .all: return true
            case .unplayed: return !isFinished(episode)
            case .played: return isFinished(episode)
            }
        }
    }
}
