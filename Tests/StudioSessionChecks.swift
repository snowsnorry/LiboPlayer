import Foundation

private final class FixtureAPI: URLProtocol {
    private static var followed = true
    private static var played = true
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let bearer = request.value(forHTTPHeaderField: "Authorization")
        precondition(url.host == "play.libolibo.me")
        var status = 200
        var body = ""
        var headers = ["Content-Type": "application/json"]
        switch (request.httpMethod!, url.path) {
        case ("GET", "/"), ("GET", ""):
            precondition(bearer == nil)
            headers["Content-Type"] = "text/html"
            body = #"""
            <script>let feeds=[{"id":"show","name":"Show","pic_200":"cover","lastEpisode":{"_seconds":100}},{"id":"other","name":"Other","lastEpisode":{"_seconds":50}}]</script>
            <script>let fresh=[{"feed":"show","createdAt":{"_seconds":210}},{"feed":"show","createdAt":{"_seconds":200}},{"feed":"show","active":false,"createdAt":{"_seconds":500}}]</script>
            <script>let tags=[{"id":"t","name":"Technology"},{"id":"t","name":"Technology"},{"id":"unused","name":"Hidden","active":false}]</script>
            """#
        case ("POST", "/authPlayer"):
            precondition(bearer == nil)
            body = #"{"token":"guest-fixture"}"#
        case ("GET", "/api/profile"):
            switch bearer {
            case "Bearer expired-fixture":
                status = 302
                headers["Location"] = "/auth"
            case "Bearer slow-fixture":
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
                return
            case "Bearer member-fixture":
                precondition(request.value(forHTTPHeaderField: "webAuthed") == "true")
                body = #"{"user":{"tgId":123,"first_name":" Анна ","last_name":"Ли","username":"@annali","paid":true,"guide":false,"played":{"a":\#(Self.played),"b":false}}}"#
            case "Bearer guest-fixture":
                precondition(request.value(forHTTPHeaderField: "webAuthed") == nil)
                body = #"{"user":{"paid":false,"guide":false}}"#
            default: preconditionFailure("Unexpected fixture identity")
            }
        case ("GET", "/api/subscriptions"):
            body = Self.followed ? #"[{"feed":"show","id":"sub","active":true}]"# : "[]"
        case ("DELETE", "/api/subscriptions/sub"), ("POST", "/api/subscriptions"):
            precondition(bearer == "Bearer member-fixture")
            Self.followed = request.httpMethod == "POST"
            status = 204
        case ("GET", "/api/tagsRelations"):
            precondition(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "t")
            body = #"[{"feed":"show"},{"feed":"show"},{"feed":"other","active":false}]"#
        case ("GET", "/api/items/a"):
            body = #"{"feed":"show","name":"A","paid":true,"track":"https://example.org/audio","description":"<p>Complete notes</p>"}"#
        case ("GET", "/api/episodes/show"):
            body = #"[{"id":"a","name":"A","paid":true,"length":"65","track":"https://example.org/audio","createdAt":{"_seconds":300},"description":" <p>About A</p> "},{"id":"a"},{"active":false,"id":"b"},{"id":"c","paid":true,"audioguide":true,"description":" "}]"#
        case ("GET", "/api/episodes/other"):
            body = #"[{"id":"d","name":"New release","createdAt":{"_seconds":400}}]"#
        case ("GET", "/api/suggest"):
            precondition(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "one & two")
            body = #"{"items":[{"id":"a","feed":"show"}],"items2":[{"id":"a","feed":"show"}]}"#
        case ("POST", "/api/played"), ("DELETE", "/api/played/a"):
            Self.played = request.httpMethod == "POST"
            precondition(bearer == "Bearer member-fixture")
            status = 204
        default: preconditionFailure("Unexpected fixture request")
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
struct StudioSessionChecks {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureAPI.self]
        let session = StudioSession(transport: URLSession(configuration: config))
        let member = StudioCredential(token: "member-fixture", signedIn: true)
        let catalog = try await session.catalog(using: member)
        precondition(catalog.account == "123" && catalog.played == ["a"] && catalog.subscriptions["show"] == "sub")
        let show = catalog.shows[0]
        precondition(session.credential?.accountID == "123")
        precondition(session.credential?.profile?.name == "Анна Ли")
        precondition(session.credential?.profile?.username == "annali")
        let legacy = try JSONDecoder().decode(StudioCredential.self, from:
            Data(#"{"token":"old","signedIn":true,"accountID":"123"}"#.utf8))
        precondition(legacy.profile == nil && legacy.signedIn)
        let recent = Show.recentlyUpdated(catalog.shows, archives: [:])
        precondition(recent.map(\.id) == ["show"] && recent.first?.lastEpisode == 210)
        precondition(catalog.categories.map(\.name) == ["Technology"])
        let members = try await session.categoryShows(catalog.categories[0])
        precondition(members == ["show"])
        let rows = try await session.episodes(for: show)
        precondition(rows.count == 2 && rows[0].duration == 65 && rows[0].streamURL != nil && rows[1].locked)
        precondition(rows[0].description == "<p>About A</p>" && rows[1].description == nil)
        let other = catalog.shows[1]
        let archives = [show.id: rows.sorted(by: Episode.precedes), other.id: try await session.episodes(for: other)]
        let updated = Show.recentlyUpdated(catalog.shows, archives: archives)
        precondition(updated.map(\.id) == [other.id, show.id] && updated.compactMap(\.lastEpisode) == [400, 300])
        precondition(Show.recentlyUpdated([show], archives: [show.id: []]).isEmpty)
        let unfollowed = try await session.setFollow(false, show: show)
        let followed = try await session.setFollow(true, show: show)
        precondition(unfollowed.isEmpty && followed["show"] == "sub")
        let stub = Episode(id: "a", showID: show.id, name: "A", published: 0, duration: 0,
                           locked: false, played: false, artwork: nil, track: nil)
        let stream = try await session.stream(for: stub)
        precondition(stream.scheme == "https")
        let matches = try await session.searchEpisodes("one & two")
        precondition(matches.count == 1 && matches[0].description == nil)
        let description = try await session.episodeDescription(matches[0].id)
        precondition(description == "<p>Complete notes</p>")
        try await session.setPlayed(false, id: "a")
        let cleared = try await session.playedIDs()
        precondition(cleared.isEmpty)
        try await session.setPlayed(true, id: "a")
        let restored = try await session.playedIDs()
        precondition(restored == ["a"])
        do {
            _ = try await session.catalog(using: StudioCredential(token: "expired-fixture", signedIn: true))
            preconditionFailure("Rejected member session silently became a guest")
        } catch LibraryError.expired {}
        do {
            _ = try await session.catalog(using: StudioCredential(token: "slow-fixture", signedIn: false))
            preconditionFailure("A timeout must preserve the guest credential")
        } catch let error as URLError { precondition(error.code == .timedOut) }
        let guest = try await session.catalog(using: StudioCredential(token: "expired-fixture", signedIn: false))
        precondition(guest.account == nil && session.credential?.token == "guest-fixture")
        precondition(session.credential?.profile == nil)
        let guestRows = try await session.episodes(for: show)
        precondition(guestRows[0].locked && guestRows[0].streamURL == nil)
        print("Native catalog, categories, episodes, search, playback marks and credential expiry checks passed.")
    }
}
