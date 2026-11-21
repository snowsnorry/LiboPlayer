import Foundation

enum StudioPayload {
    typealias Row = [String: Any]

    static func rows(from data: Data) throws -> [Row] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [Row] else { throw LibraryError.unavailable }
        return rows
    }

    static func identifier(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        return (value as? NSNumber)?.stringValue
    }

    // Match the web player's truth tests. Some API flags contain a nonempty string.
    static func flag(_ value: Any?) -> Bool {
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return !value.isEmpty }
        return value != nil && !(value is NSNull)
    }

    static func played(_ value: Any?) -> [String] {
        if let ids = value as? [Any] { return ids.compactMap { $0 as? String } }
        return (value as? Row)?.compactMap { flag($0.value) ? $0.key : nil } ?? []
    }

    private static func number(_ value: Any?) -> Double {
        if let value = value as? NSNumber { return value.doubleValue }
        return (value as? String).flatMap(Double.init) ?? 0
    }

    private static func timestamp(_ value: Any?) -> Double {
        let time = value as? Row
        return number(time?["_seconds"]) + number(time?["_nanoseconds"]) / 1e9
    }

    private static func artwork(_ row: Row, fallback: String) -> String? {
        for key in ["pic_500", "pic_200", fallback] {
            if let url = row[key] as? String, !url.isEmpty { return url }
        }
        return nil
    }

    static func shows(from data: Data) throws -> [Show] {
        // The official home page embeds the catalog as JSON in its own script element.
        guard let html = String(data: data, encoding: .utf8),
              let start = html.range(of: #"<script\b[^>]*>\s*(?:let|const|var)\s+feeds\s*=\s*"#,
                                     options: .regularExpression),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex) else {
            throw LibraryError.unavailable
        }
        let payload = html[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let json = payload.hasSuffix(";") ? payload.dropLast() : payload[...]
        let feeds = try rows(from: Data(json.utf8))
        return try feeds.sorted { timestamp($0["lastEpisode"]) > timestamp($1["lastEpisode"]) }.map { feed in
            guard let id = feed["id"] as? String, let name = feed["name"] as? String else { throw LibraryError.unavailable }
            return Show(id: id, name: name, artwork: artwork(feed, fallback: "image"))
        }
    }

    static func locked(_ row: Row, paid: Bool, guide: Bool) -> Bool {
        flag(row["paid"]) && !(flag(row["audioguide"]) ? guide : paid)
    }

    static func episodes(_ rows: [Row], showID: String?, paid: Bool, guide: Bool) -> [Episode] {
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty, let feed = showID ?? row["feed"] as? String,
                  !feed.isEmpty, row["active"] as? Bool != false, seen.insert(id).inserted else { return nil }
            let locked = locked(row, paid: paid, guide: guide)
            let name = row["name"] as? String
            return Episode(id: id, showID: feed, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Untitled Episode"),
                           published: timestamp(row["createdAt"]), duration: number(row["length"]),
                           locked: locked, played: flag(row["played"]), artwork: artwork(row, fallback: "pic"),
                           track: locked ? nil : row["track"] as? String)
        }
    }
}
