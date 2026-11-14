import CryptoKit
import UIKit

/// Getting a picked photo into the one shape the chat service takes.
///
/// The server accepts JPEG, PNG, GIF and WebP and refuses everything else at reservation — HEIC
/// included, which is what an iPhone's camera writes. Every picked image is therefore re-encoded
/// here as JPEG, scaled so its long side is at most `maxSide` and squeezed until it is under the
/// server's size limit. Nothing is uploaded from here; this only produces the bytes.
enum ImagePreparation {

    /// The server's limit for one attachment.
    static let maxBytes = 8 * 1024 * 1024

    /// The longest side sent. A screenshot stays legible at this size and a twelve-megapixel
    /// photo stops costing megabytes of upload for detail no model reads.
    static let maxSide: CGFloat = 2048

    /// The picked bytes as a JPEG within the limits, or `nil` when they are not an image this
    /// phone can read or cannot be brought under the limit.
    static func jpeg(from data: Data, maxBytes: Int = ImagePreparation.maxBytes) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scaled = scaledDown(image, maxSide: maxSide)

        for quality in [0.85, 0.7, 0.5, 0.3] as [CGFloat] {
            if let encoded = scaled.jpegData(compressionQuality: quality), encoded.count <= maxBytes {
                return encoded
            }
        }
        return nil
    }

    /// The image drawn no larger than `maxSide` on its long side, upright, at one pixel a point.
    static func scaledDown(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let pixels = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
        let longSide = max(pixels.width, pixels.height)
        guard longSide > 0 else { return image }

        let ratio = min(1, maxSide / longSide)
        let target = CGSize(
            width: max(1, (pixels.width * ratio).rounded()),
            height: max(1, (pixels.height * ratio).rounded())
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // A JPEG has no transparency; drawing opaque keeps the renderer from carrying an alpha
        // channel that would be thrown away.
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            // Drawing applies the photo's orientation, so the bytes are upright whatever way the
            // phone was held.
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// The digest the server checks the uploaded bytes against: 64 lowercase hex characters.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
