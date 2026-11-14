import SwiftUI

/// Looking something up in the fleet's memory: type what you are after, read what comes back.
///
/// The search is by meaning, not by matching words, so it is sent when asked for — on return —
/// rather than on every keystroke. Nothing is edited from here.
struct MemorySearchView: View {

    let model: MemoryModel

    @State private var query = ""

    var body: some View {
        List {
            switch model.search {
            case .idle:
                Section {
                    Text("memory.prompt")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityIdentifier.memoryPrompt.identifier)
                }

            case .searching:
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }

            case .failed(let failure):
                Section {
                    FleetStatusRow(symbolName: failure.symbolName, messageKey: failure.messageKey)
                }

            case .found(let results):
                Section {
                    if results.isEmpty {
                        Text("memory.empty")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(AccessibilityIdentifier.memoryEmpty.identifier)
                    } else {
                        ForEach(results) { result in
                            NavigationLink(value: MemoryRoute(id: result.id, title: result.title)) {
                                MemoryResultRow(result: result)
                            }
                            .accessibilityIdentifier(AccessibilityIdentifier.memoryResult.identifier)
                            .accessibilityLabel(MemoryResultRow.spokenLabel(for: result))
                        }
                    }
                } header: {
                    Text(verbatim: model.answeredQuery)
                }
            }
        }
        .navigationTitle(Text("memory.title"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text("memory.search.prompt")
        )
        .onSubmit(of: .search) {
            let asked = query
            Task { await model.run(query: asked) }
        }
        .navigationDestination(for: MemoryRoute.self) { route in
            MemoryDocumentView(model: model, route: route)
        }
    }
}

/// Where a search result leads.
struct MemoryRoute: Hashable {
    let id: String
    let title: String
}

/// Where the memory button leads.
struct MemorySearchRoute: Hashable {}

/// One search result: its title, where it belongs, and the part that matched.
struct MemoryResultRow: View {

    let result: MemorySearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: result.title)
                .font(.body)

            if let caption = Self.caption(for: result) {
                Text(verbatim: caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let snippet = result.snippet?.trimmingCharacters(in: .whitespacesAndNewlines),
               !snippet.isEmpty {
                Text(verbatim: snippet)
                    .font(.footnote)
                    .lineLimit(4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The project and the kind of memory, when it says either.
    static func caption(for result: MemorySearchResult) -> String? {
        let parts = [result.project, result.type].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func spokenLabel(for result: MemorySearchResult) -> String {
        [result.title, caption(for: result)].compactMap { $0 }.joined(separator: ". ")
    }
}

/// One memory in full. Shown as its author wrote it, as Markdown, and selectable.
struct MemoryDocumentView: View {

    let model: MemoryModel
    let route: MemoryRoute

    var body: some View {
        List {
            switch model.document(id: route.id) {
            case .loaded(let document)?:
                Section {
                    MarkdownBlocksView(text: document.content, identifier: .memoryDocumentBody)
                }

                Section {
                    if let project = document.project, !project.isEmpty {
                        fact("memory.project", project)
                    }
                    if let type = document.type, !type.isEmpty {
                        fact("memory.type", type)
                    }
                    if let agent = document.agent, !agent.isEmpty {
                        fact("memory.agent", agent)
                    }
                    if !document.tags.isEmpty {
                        fact("memory.tags", document.tags.joined(separator: ", "))
                    }
                }

            case .failed?:
                Section {
                    Label {
                        Text("memory.document.failed").font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityIdentifier.memoryDocumentFailed.identifier)
                }

            case .loading?, nil:
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(Text(verbatim: route.title))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await model.loadDocument(id: route.id)
        }
        .task {
            await model.loadDocument(id: route.id)
        }
    }

    private func fact(_ titleKey: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent {
            Text(verbatim: value)
        } label: {
            Text(titleKey)
        }
    }
}
