import SwiftUI

struct EpisodeSearchScreen: View {
    @Environment(PodcastLibrary.self) private var library
    @Binding var query: String
    let openShow: (Show) -> Void
    @State private var retry = 0
    @State private var selectedEpisode: Episode?
    @State private var response: (request: Request, result: Result<[Episode], Error>)?

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
            if response?.request == request, case let .success(episodes) = response?.result {
                ForEach(episodes) { episode in
                    EpisodeListRow(episode: episode, source: .show(episode.showID), openShow: openShow) {
                        selectedEpisode = episode
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationDestination(item: $selectedEpisode) { episode in
            EpisodeDetails(episode: episode, source: .show(episode.showID))
        }
        .overlay {
            if request.term.count < 3 {
                ContentUnavailableView("Search All Episodes", systemImage: "magnifyingglass",
                                       description: Text("Enter at least 3 characters."))
            } else if response?.request != request {
                ProgressView("Searching…")
            } else if case let .success(episodes) = response?.result {
                if episodes.isEmpty { ContentUnavailableView.search(text: request.term) }
            } else if case let .failure(error) = response?.result {
                ContentUnavailableView { Label("Couldn’t Search Episodes", systemImage: "exclamationmark.circle") }
                    description: { Text(LibraryError.message(for: error)) }
                    actions: { Button("Try Again") { retry += 1 } }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search all shows’ episodes")
        .task(id: request) {
            response = nil
            guard request.term.count >= 3 else { return }
            do {
                try await Task.sleep(for: .milliseconds(300))
                let source = try await library.sessionForRequest()
                try Task.checkCancellation()
                let episodes = try await source.searchEpisodes(request.term)
                try Task.checkCancellation()
                response = (request, .success(episodes))
            } catch {
                if !Task.isCancelled { response = (request, .failure(error)) }
            }
        }
    }
}
