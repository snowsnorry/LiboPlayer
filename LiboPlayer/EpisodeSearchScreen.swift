import SwiftUI

struct EpisodeSearchScreen: View {
    @Environment(PodcastLibrary.self) private var library
    @Binding var query: String
    @State private var retry = 0
    @State private var response: (request: Request, episodes: [Episode]?)?

    private struct Request: Equatable {
        let term: String
        let session: ObjectIdentifier
        let retry: Int
    }

    var body: some View {
        let session = library.session
        let request = Request(term: query.trimmingCharacters(in: .whitespacesAndNewlines),
                              session: ObjectIdentifier(session), retry: retry)
        List {
            if response?.request == request, let episodes = response?.episodes {
                ForEach(episodes) { episode in
                    EpisodeListRow(episode: episode, source: .show(episode.showID), showsPodcastName: true)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if request.term.count < 3 {
                ContentUnavailableView("Search All Episodes", systemImage: "magnifyingglass",
                                       description: Text("Enter at least 3 characters."))
            } else if response?.request != request {
                ProgressView("Searching…")
            } else if let episodes = response?.episodes {
                if episodes.isEmpty { ContentUnavailableView.search(text: request.term) }
            } else {
                ContentUnavailableView { Label("Couldn’t Search Episodes", systemImage: "wifi.exclamationmark") }
                    actions: { Button("Try Again") { retry += 1 } }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search all shows’ episodes")
        .task(id: request) {
            response = nil
            guard request.term.count >= 3 else { return }
            do {
                try await Task.sleep(for: .milliseconds(300))
                let episodes = try await session.searchEpisodes(request.term)
                try Task.checkCancellation()
                response = (request, episodes)
            } catch {
                if !Task.isCancelled { response = (request, nil) }
            }
        }
    }
}
