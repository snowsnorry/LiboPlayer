import Foundation

@main
struct EpisodeCollectionChecks {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shelf = EpisodeCollection(account: "one", root: root)
        let show = Show(id: "show", name: "Show", artwork: nil)
        let episode = Episode(id: "episode", showID: show.id, name: "Episode", published: 1, duration: 10,
                              locked: false, played: false, artwork: nil, track: nil)
        precondition(shelf.saved.isEmpty && shelf.downloaded.isEmpty)
        try shelf.setSaved(true, episode: episode, show: show)
        precondition(shelf.saved == [episode] && shelf.downloaded.isEmpty)
        precondition(shelf.beginDownload(episode.id) && !shelf.beginDownload(episode.id))
        let partial = root.appending(component: "missing")
        do {
            try shelf.install(partial, episode: episode, show: show, extension: "mp3")
            preconditionFailure("Missing file should fail")
        } catch { shelf.endDownload(episode.id) }
        precondition(shelf.beginDownload(episode.id) && shelf.downloaded.isEmpty)
        let temp = root.appending(component: "incoming")
        let audio = Data([1, 2, 3, 4])
        try audio.write(to: temp)
        try shelf.install(temp, episode: episode, show: show, extension: "mp3")
        shelf.endDownload(episode.id)
        let restored = EpisodeCollection(account: "one", root: root)
        precondition(restored.saved == [episode] && restored.downloaded == [episode])
        let file = restored.localURL(episode.id)!
        let bytes = try Data(contentsOf: file)
        precondition(bytes == audio && restored.cachedShow(show.id) == show)
        for owner in [nil, "two"] as [String?] {
            let separate = EpisodeCollection(account: owner, root: root)
            precondition(separate.saved.isEmpty && separate.downloaded.isEmpty && separate.cachedShow(show.id) == nil)
        }
        try restored.setSaved(false, episode: episode, show: show)
        precondition(restored.saved.isEmpty && restored.downloaded == [episode] && restored.cachedShow(show.id) == show)
        try restored.setSaved(true, episode: episode, show: show)
        try restored.removeDownload(episode.id)
        precondition(!FileManager.default.fileExists(atPath: file.path) && restored.saved == [episode])
        try audio.write(to: temp)
        try restored.install(temp, episode: episode, show: show, extension: "mp3")
        try FileManager.default.removeItem(at: restored.localURL(episode.id)!)
        let repaired = EpisodeCollection(account: "one", root: root)
        precondition(repaired.downloaded.isEmpty && repaired.saved == [episode])
        // Previous versions also stored the studio record ID alongside each saved episode.
        let legacy = root.appending(path: "EpisodeCollections/guest/index.json")
        let legacyJSON = #"{"bookmarks":{"episode":{"record":"web-record","episode":{"id":"episode","showID":"show","name":"Episode","published":1,"duration":10,"locked":false,"played":false}}},"downloads":{},"shows":{}}"#
        try Data(legacyJSON.utf8).write(to: legacy)
        let guest = EpisodeCollection(account: nil, root: root)
        precondition(guest.saved == [episode])
        try guest.setSaved(false, episode: episode, show: show)
        precondition(EpisodeCollection(account: nil, root: root).saved.isEmpty)
        precondition(EpisodeCollection(account: "one", root: root).isSaved(episode.id))
        print("Independent collections, account isolation, download retry and offline restoration passed.")
    }
}
