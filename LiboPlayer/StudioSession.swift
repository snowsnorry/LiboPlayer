import Foundation
import OSLog

enum StudioSite {
    static let home = URL(string: "https://play.libolibo.me/")!

    static func isPlayer(_ url: URL?) -> Bool {
        url?.scheme == "https" && url?.host == home.host && (url?.port == nil || url?.port == 443)
    }
}

struct Catalog {
    let account: String?
    let shows: [Show]
    let subscriptions: [String: String]
    let played: [String]
}

enum LibraryError: LocalizedError {
    case unavailable, timedOut, offline, expired, noAudio, locked
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "Couldn’t load Libo/Libo. Try again.")
        case .timedOut: String(localized: "Libo/Libo took too long to respond. Try again.")
        case .offline: String(localized: "You’re offline. Check your internet connection and try again.")
        case .expired: String(localized: "Sign in with Telegram to confirm your account.")
        case .noAudio: String(localized: "Audio is currently unavailable for this episode.")
        case .locked: String(localized: "This episode requires a Libo/Libo subscription.")
        }
    }
    static func message(for error: Error) -> String {
        if let error = error as? LibraryError { return error.localizedDescription }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return LibraryError.timedOut.localizedDescription
            case .notConnectedToInternet: return LibraryError.offline.localizedDescription
            default: break
            }
        }
        return LibraryError.unavailable.localizedDescription
    }
}

/// The API redirects rejected sessions to an HTML sign-in page. Inspect the original response.
private final class StudioRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class StudioSession {
    private static let transport: URLSession = {
        let settings = URLSessionConfiguration.ephemeral
        settings.httpShouldSetCookies = false
        settings.urlCredentialStorage = nil
        settings.urlCache = nil
        settings.timeoutIntervalForRequest = 45
        settings.timeoutIntervalForResource = 90
        return URLSession(configuration: settings, delegate: StudioRedirects(), delegateQueue: nil)
    }()
    private let transport: URLSession
    private(set) var credential: StudioCredential?
    private(set) var isAvailable = false
    private var paid = false
    private var guide = false

    init(transport: URLSession? = nil) { self.transport = transport ?? Self.transport }

    private func request(_ path: [String], method: String = "GET", query: [URLQueryItem] = [],
                         body: [String: String]? = nil, credential: StudioCredential? = nil) async throws -> Data {
        guard path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw LibraryError.unavailable }
        let endpoint = path.reduce(StudioSite.home) { $0.appending(component: $1) }
        var request = URLRequest(url: query.isEmpty ? endpoint : endpoint.appending(queryItems: query))
        request.httpMethod = method
        if let credential {
            request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
            if credential.signedIn { request.setValue("true", forHTTPHeaderField: "webAuthed") }
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LibraryError.unavailable }
        if http.statusCode == 401 { throw LibraryError.expired }
        if (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"),
           let url = URL(string: location, relativeTo: endpoint)?.absoluteURL,
           StudioSite.isPlayer(url), url.path == "/auth" { throw LibraryError.expired }
        guard (200..<300).contains(http.statusCode),
              path.isEmpty || http.mimeType != "text/html" else { throw LibraryError.unavailable }
        return data
    }

    private func api(_ path: [String], method: String = "GET", query: [URLQueryItem] = [],
                     body: [String: String]? = nil) async throws -> Data {
        guard let credential else { throw LibraryError.expired }
        do { return try await request(["api"] + path, method: method, query: query, body: body, credential: credential) }
        catch LibraryError.expired {
            isAvailable = false
            throw LibraryError.expired
        }
    }

    private func guest() async throws -> StudioCredential {
        struct Guest: Decodable { let token: String }
        let data = try await request(["authPlayer"], method: "POST")
        let token = try JSONDecoder().decode(Guest.self, from: data).token
        guard !token.isEmpty else { throw LibraryError.unavailable }
        return StudioCredential(token: token, signedIn: false)
    }

    func catalog(using saved: StudioCredential?) async throws -> Catalog {
        if let saved { credential = saved } else { credential = try await guest() }
        let user: [String: Any]
        do { user = try await profile() }
        catch LibraryError.expired where saved?.signedIn == false {
            credential = try await guest()
            user = try await profile()
        }
        let account = StudioPayload.identifier(user["tgId"])
        if credential?.signedIn == true && account == nil { throw LibraryError.expired }
        if let current = credential, account != nil && !current.signedIn {
            credential = StudioCredential(token: current.token, signedIn: true)
        }
        let subscriptions = try await readSubscriptions()
        let shows = try StudioPayload.shows(from: await request([]))
        paid = StudioPayload.flag(user["paid"])
        guide = StudioPayload.flag(user["guide"])
        isAvailable = true
        Logger(subsystem: "app.liboplayer.ios", category: "StudioSession").notice("Native catalog loaded")
        return Catalog(account: account, shows: shows, subscriptions: subscriptions,
                       played: StudioPayload.played(user["played"]))
    }

    private func profile() async throws -> [String: Any] {
        let data = try await api(["profile"])
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = response["user"] as? [String: Any] else { throw LibraryError.unavailable }
        return user
    }

    private func readSubscriptions() async throws -> [String: String] {
        let rows = try StudioPayload.rows(from: await api(["subscriptions"]))
        var subscriptions: [String: String] = [:]
        for row in rows where StudioPayload.flag(row["active"]) {
            if let feed = row["feed"] as? String, let id = row["id"] as? String { subscriptions[feed] = id }
        }
        return subscriptions
    }

    func episodes(for show: Show) async throws -> [Episode] {
        let rows = try StudioPayload.rows(from: await api(["episodes", show.id]))
        return StudioPayload.episodes(rows, showID: show.id, paid: paid, guide: guide)
    }

    func searchEpisodes(_ term: String) async throws -> [Episode] {
        let data = try await api(["suggest"], query: [URLQueryItem(name: "name", value: term)])
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = result["items"] as? [[String: Any]], let more = result["items2"] as? [[String: Any]]
        else { throw LibraryError.unavailable }
        return StudioPayload.episodes(items + more, showID: nil, paid: paid, guide: guide)
    }

    func stream(for episode: Episode) async throws -> URL {
        guard !episode.locked else { throw LibraryError.locked }
        if let url = episode.streamURL { return url }
        let data = try await api(["items", episode.id])
        guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LibraryError.unavailable }
        guard !StudioPayload.locked(row, paid: paid, guide: guide) else { throw LibraryError.locked }
        guard let track = row["track"] as? String, let url = URL(string: track), url.scheme == "https" else { throw LibraryError.noAudio }
        return url
    }

    func setPlayed(_ played: Bool, id: String) async throws {
        if played { _ = try await api(["played"], method: "POST", body: ["item": id]) }
        else { _ = try await api(["played", id], method: "DELETE") }
    }

    func setFollow(_ following: Bool, show: Show) async throws -> [String: String] {
        let before = try await readSubscriptions()
        if let id = before[show.id] {
            guard !following else { return before }
            _ = try await api(["subscriptions", id], method: "DELETE")
        } else {
            guard following else { return before }
            _ = try await api(["subscriptions"], method: "POST", body: ["feed": show.id])
        }
        let after = try await readSubscriptions()
        guard (after[show.id] != nil) == following else { throw LibraryError.unavailable }
        return after
    }
}
