import Foundation
import Observation

/// The bytes of the images in one thread, read when a row that shows one comes on screen.
///
/// In memory only, and only the most recent few: an image is read again from the server when it
/// is needed again. An image this phone has just sent is kept from the upload, so its own row
/// shows it without a download.
@MainActor
@Observable
final class AttachmentImages {

    enum State: Equatable, Sendable {
        case loading
        case loaded(Data)
        /// The bytes could not be read: expired on the server, or the server did not answer.
        case failed
    }

    /// How many images are kept. Past it the oldest goes.
    nonisolated static let limit = 24

    private let fetch: (String) async throws -> Data

    private(set) var states: [String: State] = [:]
    private var order: [String] = []

    init(fetch: @escaping (String) async throws -> Data) {
        self.fetch = fetch
    }

    func state(for attachmentId: String) -> State? {
        states[attachmentId]
    }

    func data(for attachmentId: String) -> Data? {
        if case .loaded(let data)? = states[attachmentId] { return data }
        return nil
    }

    /// Keeps bytes this phone already holds, under the identifier the server gave them.
    func store(_ data: Data, for attachmentId: String) {
        set(.loaded(data), for: attachmentId)
    }

    /// Reads one image, unless it is here or on its way. A failed read is tried again the next
    /// time it is asked for.
    func load(_ attachmentId: String) async {
        switch states[attachmentId] {
        case .loaded?, .loading?:
            return
        case .failed?, nil:
            break
        }
        set(.loading, for: attachmentId)
        do {
            let data = try await fetch(attachmentId)
            set(.loaded(data), for: attachmentId)
        } catch {
            set(.failed, for: attachmentId)
        }
    }

    private func set(_ state: State, for attachmentId: String) {
        if states[attachmentId] == nil {
            order.append(attachmentId)
        }
        states[attachmentId] = state
        while order.count > Self.limit {
            let evicted = order.removeFirst()
            states[evicted] = nil
        }
    }
}
