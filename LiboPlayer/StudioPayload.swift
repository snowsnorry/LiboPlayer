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
        #if os(watchOS)
        return WatchArtwork.address(row["pic_200"] as? String, row["pic_500"] as? String, row[fallback] as? String)
        #else
        for key in ["pic_500", "pic_200", fallback] {
            if let url = row[key] as? String, !url.isEmpty { return url }
        }
        return nil
        #endif
    }

    private static func embeddedRows(_ name: String, in data: Data) throws -> [Row]? {
        guard let html = String(data: data, encoding: .utf8) else { throw LibraryError.unavailable }
        let pattern = #"<script\b[^>]*>\s*(?:let|const|var)\s+"# + name + #"\s*=\s*"#
        guard let start = html.range(of: pattern, options: .regularExpression) else { return nil }
        guard let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex) else {
            throw LibraryError.unavailable
        }
        let payload = html[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let json = payload.hasSuffix(";") ? payload.dropLast() : payload[...]
        return try rows(from: Data(json.utf8))
    }

    static func shows(from data: Data) throws -> [Show] {
        guard let feeds = try embeddedRows("feeds", in: data) else { throw LibraryError.unavailable }
        // The catalog's lastEpisode is an old ordering hint. The fresh list contains real publications.
        let fresh = (try? embeddedRows("fresh", in: data)) ?? []
        var published: [String: Double] = [:]
        for row in fresh where row["active"] as? Bool != false {
            guard let id = row["feed"] as? String else { continue }
            let date = timestamp(row["createdAt"])
            if date > (published[id] ?? 0) { published[id] = date }
        }
        return try feeds.sorted { timestamp($0["lastEpisode"]) > timestamp($1["lastEpisode"]) }.map { feed in
            guard let id = feed["id"] as? String, let name = feed["name"] as? String else { throw LibraryError.unavailable }
            return Show(id: id, name: name, artwork: artwork(feed, fallback: "image"), lastEpisode: published[id])
        }
    }

    static func categories(from data: Data) throws -> [StudioCategory] {
        var seen = Set<String>()
        return try (embeddedRows("tags", in: data) ?? []).compactMap { row in
            guard row["active"] as? Bool != false, let id = identifier(row["id"]), let name = row["name"] as? String,
                  seen.insert(id).inserted else { return nil }
            return StudioCategory(id: id, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func locked(_ row: Row, paid: Bool, guide: Bool) -> Bool {
        flag(row["paid"]) && !(flag(row["audioguide"]) ? guide : paid)
    }

    static func description(in row: Row) -> String? {
        guard let text = row["description"] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
                           track: locked ? nil : row["track"] as? String,
                           access: flag(row["paid"]) ? (flag(row["audioguide"]) ? .guide : .subscription) : nil,
                           description: description(in: row))
        }
    }
}
