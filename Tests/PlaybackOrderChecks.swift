import Foundation

@main
struct PlaybackOrderChecks {
    static func episode(_ id: String, show: String, date: Double, locked: Bool = false) -> Episode {
        Episode(id: id, showID: show, name: id, published: date, duration: 600, locked: locked,
                played: false, artwork: nil, track: nil)
    }

    static func main() throws {
        let current = episode("a3", show: "A", date: 40)
        let finished = episode("b2", show: "B", date: 30)
        let partial = episode("b1", show: "B", date: 20)
        let fresh = episode("a1", show: "A", date: 10)
        let locked = episode("x", show: "B", date: 25, locked: true)
        let feed = [fresh, partial, current, locked, finished].sorted(by: Episode.precedes)
        precondition(feed.map(\.id) == ["a3", "b2", "x", "b1", "a1"])
        var history = ListeningHistory()
        history.finish(finished.id)
        history.positions[partial.id] = 83
        history = try JSONDecoder().decode(ListeningHistory.self, from: JSONEncoder().encode(history))
        func next(_ item: Episode, in rows: [Episode]) -> Episode? {
            Episode.next(after: item, in: rows) { history.completed.contains($0.id) }
        }
        precondition(next(current, in: feed) == partial && history.resume(partial) == 83)
        precondition(next(current, in: feed.filter { $0.showID != current.showID }) == partial)
        history.finish(partial.id)
        precondition(next(current, in: feed) == fresh && history.resume(fresh) == 0)
        precondition(next(fresh, in: feed) == nil)
        let simultaneous = episode("z", show: "B", date: current.published)
        precondition(next(current, in: [current, simultaneous]) == simultaneous)
        try checkListeningFilters()
        print("Playback order, resume, listening status, history migration and title filters passed.")
    }

    private static func checkListeningFilters() throws {
        let oldData = Data(#"{"positions":{"История":83},"completed":["Финал"]}"#.utf8)
        var history = try JSONDecoder().decode(ListeningHistory.self, from: oldData)
        precondition(history.pendingMarks == ["Финал": true])
        var pending = history
        pending.markUnplayed("Финал")
        pending.acknowledge("Финал", played: true)
        precondition(pending.pendingMarks == ["Финал": false])
        pending.positions["Финал"] = 12
        pending.acknowledge("Финал", played: false)
        precondition(pending.pendingMarks.isEmpty && pending.positions["Финал"] == 12)
        precondition(pending.isFinished("Финал", serverPlayed: true))
        precondition(!pending.isFinished("Финал", serverPlayed: false))
        let partial = episode("История", show: "A", date: 20)
        let played = episode("Финал", show: "A", date: 10)
        let serverPlayed = episode("История науки", show: "B", date: 5)
        let episodes = [partial, played, serverPlayed]
        func finished(_ episode: Episode) -> Bool {
            history.isFinished(episode.id, serverPlayed: episode == serverPlayed)
        }
        var query = EpisodeQuery()
        precondition(query.results(in: episodes, isFinished: finished) == episodes)
        query.filter = .unplayed
        precondition(query.results(in: episodes, isFinished: finished) == [partial])
        precondition(history.resume(partial) == 83)
        query.title = "  ИСТОР  "
        query.filter = .played
        precondition(query.results(in: episodes, isFinished: finished) == [serverPlayed])
        history.finish(partial.id)
        precondition(history.resume(partial) == 0)
        precondition(query.results(in: episodes, isFinished: finished) == [partial, serverPlayed])
        history.markUnplayed(serverPlayed.id)
        history = try JSONDecoder().decode(ListeningHistory.self, from: JSONEncoder().encode(history))
        precondition(query.results(in: episodes, isFinished: finished) == [partial])
        query.filter = .unplayed
        precondition(query.results(in: episodes, isFinished: finished) == [serverPlayed])
        query.title = "missing"
        precondition(query.results(in: episodes, isFinished: finished).isEmpty)
        history.finish(serverPlayed.id)
        precondition(finished(serverPlayed))
        history.clearLocalStatus(partial.id)
        precondition(!finished(partial))
    }
}
