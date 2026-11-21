import Foundation

@main
struct EpisodeCollectionChecks {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shelf = EpisodeCollection(account: "one", root: root)
        let show = Show(id: "show", name: "Show", artwork: nil)
        let episode = Episode(id: "episode", showID: show.id, name: "Episode", published: 1, duration: 10,
                              locked: false, played: false, artwork: nil, track: nil, description: "<p>Episode notes</p>")
        precondition(shelf.saved.isEmpty && shelf.downloaded.isEmpty)
        try shelf.setSaved(true, episode: episode, show: show)
        precondition(shelf.saved == [episode] && shelf.downloaded.isEmpty)
        guard let firstDownload = shelf.beginDownload(episode.id) else { preconditionFailure("Download did not start") }
        precondition(shelf.beginDownload(episode.id) == nil && firstDownload.fractionCompleted == nil)
        firstDownload.update(0.5)
        firstDownload.update(0.25)
        precondition(firstDownload.fractionCompleted == 0.5)
        let partial = root.appending(component: "missing")
        do {
            try shelf.install(partial, episode: episode, show: show, extension: "mp3")
            preconditionFailure("Missing file should fail")
        } catch { shelf.endDownload(episode.id) }
        guard let retry = shelf.beginDownload(episode.id) else { preconditionFailure("Download did not restart") }
        precondition(retry.fractionCompleted == nil && shelf.downloaded.isEmpty)
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
        precondition(guest.saved.map(\.id) == [episode.id] && guest.saved[0].description == nil)
        try guest.setSaved(false, episode: episode, show: show)
        precondition(EpisodeCollection(account: nil, root: root).saved.isEmpty)
        precondition(EpisodeCollection(account: "one", root: root).isSaved(episode.id))
        // Paired devices exchange bookmark metadata only. Replaying a snapshot must not
        // undo an offline removal, copy an audio file, or cross the account boundary.
        let phone = EpisodeCollection(account: "one", root: root)
        let watchRoot = root.appending(component: "watch")
        let watch = EpisodeCollection(account: "one", root: watchRoot)
        let original = phone.bookmarkSnapshot()
        try watch.mergeBookmarks(original, access: { $0 })
        precondition(watch.saved == phone.saved && watch.cachedShow(show.id) == show)
        try watch.setSaved(false, episode: episode, show: show)
        let removal = watch.bookmarkSnapshot()
        try watch.mergeBookmarks(original, access: { $0 })
        try phone.mergeBookmarks(removal, access: { $0 })
        precondition(phone.saved.isEmpty && watch.saved.isEmpty)
        try phone.setSaved(true, episode: episode, show: show)
        try audio.write(to: temp)
        try phone.install(temp, episode: episode, show: show, extension: "mp3")
        try watch.mergeBookmarks(phone.bookmarkSnapshot(), access: { $0 })
        try watch.mergeBookmarks(removal, access: { $0 })
        precondition(watch.saved == [episode] && watch.downloaded.isEmpty)
        try audio.write(to: temp)
        try watch.install(temp, episode: episode, show: show, extension: "mp3")
        try watch.removeDownload(episode.id)
        precondition(watch.saved == [episode] && phone.downloaded == [episode])
        let otherOwner = EpisodeCollection(account: "two", root: watchRoot)
        try otherOwner.mergeBookmarks(original, access: { $0 })
        precondition(otherOwner.saved.isEmpty)
        let coldWatch = EpisodeCollection(account: "one", root: watchRoot)
        try coldWatch.mergeBookmarks(removal, access: { $0 })
        precondition(coldWatch.saved == [episode])
        print("Independent collections, account isolation, download retry and offline restoration passed.")
    }
}
