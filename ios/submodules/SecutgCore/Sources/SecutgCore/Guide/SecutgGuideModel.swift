import Foundation

/// PLAN.md 3.15: the shape of `secutg-guide.json`, the single source of the encryption guide on every client.
/// The content itself ships as generated source (`SecutgGuideData.generated.swift` in TelegramCore) rather than as a
/// bundle resource; this module only knows how to read it, so the layout arithmetic stays testable without any UI.
public typealias SecutgGuideText = [String: String]

/// One drawable element of a scene. `k` and `style` stay strings, exactly like the TypeScript string unions,
/// so an unknown value from a newer content file is ignored instead of failing the whole parse.
public struct SecutgSceneItem: Equatable, Codable {
    /// `in` `out` `service` `body` `row` `item` `button` `code` `qr` `input`
    public let k: String
    /// the text, per language
    public let t: SecutgGuideText?
    /// the trailing value of a settings row, per language
    public let v: SecutgGuideText?
    /// `plain` `strong` `hl` `danger` `warn` `caption` `primary`
    public let style: String?

    public init(k: String, t: SecutgGuideText? = nil, v: SecutgGuideText? = nil, style: String? = nil) {
        self.k = k
        self.t = t
        self.v = v
        self.style = style
    }
}

public struct SecutgScene: Equatable, Codable {
    /// `chat` (avatar, title, lock button) or `page` (back arrow, centred title)
    public let chrome: String
    public let title: SecutgGuideText?
    public let subtitle: SecutgGuideText?
    /// `on` `off` `warn` `none`
    public let lock: String?
    /// `none` `sheet` `dialog`
    public let sheet: String
    public let items: [SecutgSceneItem]

    public init(chrome: String, title: SecutgGuideText? = nil, subtitle: SecutgGuideText? = nil, lock: String? = nil, sheet: String, items: [SecutgSceneItem]) {
        self.chrome = chrome
        self.title = title
        self.subtitle = subtitle
        self.lock = lock
        self.sheet = sheet
        self.items = items
    }
}

public struct SecutgGuideStep: Equatable, Codable {
    public let id: String
    public let title: SecutgGuideText
    public let body: SecutgGuideText
    /// which control the second-stage in-app walkthrough points at
    public let anchor: String?
    public let scene: SecutgScene
}

public struct SecutgGuideChapter: Equatable, Codable {
    public let id: String
    public let icon: String
    public let title: SecutgGuideText
    public let summary: SecutgGuideText
    public let steps: [SecutgGuideStep]
}

public struct SecutgGuide: Equatable, Codable {
    public let languages: [String]
    public let chapters: [SecutgGuideChapter]

    /// The four chapters PLAN.md 3.15 fixes, in order.
    public static let chapterOrder = ["private", "member", "admin", "other"]

    /// Parses the generated JSON once. The caller caches the result; parsing is deliberately lazy so a user who
    /// never opens the guide never pays for it.
    public static func parse(json: String) throws -> SecutgGuide {
        return try parse(data: Data(json.utf8))
    }

    public static func parse(data: Data) throws -> SecutgGuide {
        return try JSONDecoder().decode(SecutgGuide.self, from: data)
    }

    public func chapter(id: String) -> SecutgGuideChapter? {
        return chapters.first(where: { $0.id == id })
    }
}
