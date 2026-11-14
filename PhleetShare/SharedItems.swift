import Foundation
import UniformTypeIdentifiers

/// Reads what another app handed over: text, a web address, images.
///
/// Whatever arrives is someone else's data and is treated as such. An address is kept only when
/// it opens a web page; an image is only bytes until `ShareModel` has re-encoded it; anything
/// else is left where it was.
enum SharedItems {

    @MainActor
    static func load(from context: NSExtensionContext?, into model: ShareModel) async {
        let items = context?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers = items.flatMap { $0.attachments ?? [] }

        var texts: [String] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                // No bytes is the same failure as bytes that are not an image, and is counted
                // the same way.
                model.add(image: await data(from: provider, type: .image) ?? Data())
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = await url(from: provider), isWebAddress(url) {
                    texts.append(url.absoluteString)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = await text(from: provider) {
                    texts.append(text)
                }
            }
        }
        model.add(texts: texts)
    }

    /// `http` or `https` and nothing else. A file address names something on this phone that
    /// the agent cannot read, and would tell it only a path.
    static func isWebAddress(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func data(from provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func url(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private static func text(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                continuation.resume(returning: text)
            }
        }
    }
}
