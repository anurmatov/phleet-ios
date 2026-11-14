import Foundation
import Observation

/// Looking something up in the fleet's shared memory.
///
/// Read-only. A search is sent when the person asks for one, not on every keystroke: each one is
/// an embedding lookup on the server. Writing and deleting memories stay on the web dashboard.
@MainActor
@Observable
final class MemoryModel {

    enum Search: Equatable, Sendable {
        /// Nothing has been asked yet.
        case idle
        case searching
        /// The search answered. It may have found nothing.
        case found([MemorySearchResult])
        case failed(ControlPlaneModel.Failure)
    }

    enum Document: Equatable, Sendable {
        case loading
        case loaded(MemoryDocument)
        case failed
    }

    private let api: ControlAPIClient
    private let connection: ControlConnection

    private(set) var search: Search = .idle

    /// What the results on screen answer. Kept so a result list is never shown under other words.
    private(set) var answeredQuery = ""

    /// By memory identifier.
    private(set) var documents: [String: Document] = [:]

    /// Moves on with every search. An answer to an earlier one changes nothing.
    private var generation = 0

    init(api: ControlAPIClient, connection: ControlConnection) {
        self.api = api
        self.connection = connection
    }

    /// Searches for `text`. Blank text clears the results rather than asking the server for
    /// everything.
    func run(query text: String) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1
        let asked = generation

        guard !query.isEmpty else {
            answeredQuery = ""
            search = .idle
            return
        }

        search = .searching
        do {
            let results = try await api.searchMemory(connection, query: query)
            guard asked == generation else { return }
            answeredQuery = query
            search = .found(results)
        } catch {
            guard asked == generation, !Task.isCancelled else { return }
            search = .failed(ControlPlaneModel.Failure.from(error))
        }
    }

    func document(id: String) -> Document? {
        documents[id]
    }

    /// Reads one memory in full. A reload keeps what is on screen until the new read arrives.
    func loadDocument(id: String) async {
        if documents[id] == nil {
            documents[id] = .loading
        }
        do {
            documents[id] = .loaded(try await api.memory(connection, id: id))
        } catch {
            guard !Task.isCancelled else { return }
            if case .loaded? = documents[id] { return }
            documents[id] = .failed
        }
    }
}
