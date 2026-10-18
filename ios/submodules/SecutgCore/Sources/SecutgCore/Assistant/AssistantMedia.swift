import Foundation

/// 2026-10-10: the assistant reads a chat's pictures.
///
/// Every message shape (`mention`'s message, `context_before` / `context_after`, `context` and `history`) carries an
/// optional `media` array describing what is attached — kind, MIME type, size, dimensions, file name, never the
/// bytes. The `media` op then hands over one item's bytes (base64) when it is a picture: a photo, or a document
/// whose MIME type is an image. Read only; no chat state changes and no picture content is ever logged.
public enum AssistantMediaKind: String, CaseIterable, Equatable {
    case photo, document, video, sticker
}

/// One attachment of a message as listed in `media`. `index` is its position in that list (what the `media` op
/// takes back); `size` is bytes, or null when the client does not know it yet.
public struct AssistantMediaItem: Equatable {
    public let index: Int
    public let kind: AssistantMediaKind
    public let mime: String
    public let size: Int64?
    public let width: Int?
    public let height: Int?
    public let fileName: String?

    public init(index: Int, kind: AssistantMediaKind, mime: String, size: Int64?, width: Int?, height: Int?, fileName: String? = nil) {
        self.index = index
        self.kind = kind
        self.mime = mime
        self.size = size
        self.width = width
        self.height = height
        self.fileName = fileName
    }

    public var json: AssistantJSON {
        var fields: [String: AssistantJSON] = [
            "index": .int(Int64(index)), "kind": .string(kind.rawValue), "mime": .string(mime),
            "size": .optionalInt(size), "width": .optionalInt(width.map(Int64.init)), "height": .optionalInt(height.map(Int64.init)),
        ]
        if let fileName { fields["file_name"] = .string(fileName) }
        return .object(fields)
    }
}

public enum AssistantMediaPolicy {
    /// Picture formats the `media` op hands over. SVG is left out on purpose: it is a document that can carry
    /// script and links, not pixels.
    public static let imageMimeTypes: Set<String> = [
        "image/jpeg", "image/jpg", "image/png", "image/gif", "image/webp", "image/heic", "image/heif", "image/bmp", "image/tiff",
    ]

    /// Whether the `media` op serves this item: every photo, and a document whose MIME type is a picture. Video
    /// and stickers are `unsupported`.
    public static func isServable(kind: AssistantMediaKind, mime: String) -> Bool {
        switch kind {
        case .photo: return true
        case .document: return imageMimeTypes.contains(mime.lowercased())
        case .video, .sticker: return false
        }
    }

    /// The failure for an item of `size` bytes against the caller's `maxBytes`, or nil when it fits. An unknown
    /// size fits until the bytes are in hand.
    public static func sizeRefusal(size: Int64?, maxBytes: Int64) -> AssistantFailure? {
        guard let size, size > maxBytes else { return nil }
        return AssistantFailure(.tooLarge, "media is \(size) bytes, more than max_bytes \(maxBytes)")
    }

    /// Lowercase hex SHA-256 of `data`.
    public static func sha256Hex(_ data: Data) -> String {
        return V2Suite.sha256([UInt8](data)).map { String(format: "%02x", $0) }.joined()
    }
}

extension AssistantResults {
    /// `media`: the picture's bytes, base64, with their type, length and SHA-256.
    public static func media(mime: String, data: Data) -> [String: AssistantJSON] {
        return [
            "mime": .string(mime), "size": .int(Int64(data.count)),
            "sha256": .string(AssistantMediaPolicy.sha256Hex(data)), "data_base64": .string(data.base64EncodedString()),
        ]
    }
}
