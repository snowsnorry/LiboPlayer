import Foundation

private final class FixtureAPI: URLProtocol {
    private static var followed = true
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
            body = #"<script>let feeds=[{"id":"show","name":"Show","pic_200":"cover"}]</script>"#
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
                body = #"{"user":{"tgId":123,"paid":true,"guide":false,"played":{"a":true,"b":false}}}"#
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
        case ("GET", "/api/items/a"):
            body = #"{"paid":true,"track":"https://example.org/audio"}"#
        case ("GET", "/api/episodes/show"):
            body = #"[{"id":"a","name":"A","paid":true,"length":"65","track":"https://example.org/audio"},{"id":"a"},{"active":false,"id":"b"},{"id":"c","paid":true,"audioguide":true}]"#
        case ("GET", "/api/suggest"):
            precondition(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "one & two")
            body = #"{"items":[{"id":"a","feed":"show"}],"items2":[{"id":"a","feed":"show"}]}"#
        case ("POST", "/api/played"), ("DELETE", "/api/played/a"):
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
        let rows = try await session.episodes(for: show)
        precondition(rows.count == 2 && rows[0].duration == 65 && rows[0].streamURL != nil && rows[1].locked)
        let unfollowed = try await session.setFollow(false, show: show)
        let followed = try await session.setFollow(true, show: show)
        precondition(unfollowed.isEmpty && followed["show"] == "sub")
        let stub = Episode(id: "a", showID: show.id, name: "A", published: 0, duration: 0,
                           locked: false, played: false, artwork: nil, track: nil)
        let stream = try await session.stream(for: stub)
        precondition(stream.scheme == "https")
        let matches = try await session.searchEpisodes("one & two")
        precondition(matches.count == 1)
        try await session.setPlayed(true, id: "a")
        try await session.setPlayed(false, id: "a")
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
        let guestRows = try await session.episodes(for: show)
        precondition(guestRows[0].locked && guestRows[0].streamURL == nil)
        print("Native catalog, episodes, search, playback marks and credential expiry checks passed.")
    }
}
