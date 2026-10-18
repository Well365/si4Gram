import Foundation

/// The `crypto` section of secutg.json, same schema as every other client.
public struct CryptoConfig: Equatable {
    public let epochDays: Int
    public let epochTolerance: Int
    public let rekeyReminderDays: Int
    public let maxPlaintextChars: Int

    public init(epochDays: Int, epochTolerance: Int, rekeyReminderDays: Int, maxPlaintextChars: Int) {
        self.epochDays = epochDays
        self.epochTolerance = epochTolerance
        self.rekeyReminderDays = rekeyReminderDays
        self.maxPlaintextChars = maxPlaintextChars
    }

    public static let defaults = CryptoConfig(epochDays: 1, epochTolerance: 1, rekeyReminderDays: 7, maxPlaintextChars: 3000)
}

/// PLAN.md 3.11: who distributes this build. Read ONLY from the bundled secutg.json, never from the
/// environment or the user file, so a runtime override cannot dress up a repackaged build as the official one.
public struct DistributionConfig: Equatable {
    public let version: String?
    public let channel: String?
    public let site: String?
    public let source: String?
    public let contact: String?
    /// git short hash · build date, written by the build script (Bazel-generated `SecutgBuildInfo` on iOS)
    public let build: String?
    // SECUTG-HOOK (PLAN.md 3.48.8): new optional field for the relay guide page; every other field here is
    // unaffected, and an old secutg.json with no `relay_source` resolves exactly as before (nil).
    /// PLAN.md 3.48.8: the relay service's own source repository, shown on the relay guide page's "源码（GitHub）"
    /// row. Read the same way as `source` above (built-in secutg.json only); kept as a separate field rather than
    /// reusing `source` because that one names this *app's* source, not the relay service's.
    public let relaySource: String?
    /// PLAN.md 3.52: the assistant's own source repository, shown on the 智能助手服务部署 page. Same rules as
    /// `relaySource` (built-in secutg.json only, optional); an old secutg.json without it resolves to nil.
    public let assistantSource: String?
    // SECUTG-HOOK (PLAN.md 3.53): 〔Telegram FAQ〕 row on the main settings page — built-in-only, optional, just
    // like `relaySource` / `assistantSource`; an old secutg.json without it resolves to nil (row hidden).
    /// PLAN.md 3.53: the URL shown for 〔Telegram FAQ〕, https-only, validated by `FaqUrl.validate`.
    public let faq: String?

    public init(version: String? = nil, channel: String? = nil, site: String? = nil, source: String? = nil, contact: String? = nil, build: String? = nil, relaySource: String? = nil, assistantSource: String? = nil, faq: String? = nil) {
        self.version = version
        self.channel = channel
        self.site = site
        self.source = source
        self.contact = contact
        self.build = build
        self.relaySource = relaySource
        self.assistantSource = assistantSource
        self.faq = faq
    }
}

/// PLAN.md 3.15: one sponsor entry — a label and the value the client turns into a QR code or a copyable address.
public struct SponsorEntry: Equatable {
    public let label: String
    /// payment link or address — the client draws the QR code itself, no bundled images
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct SponsorLink: Equatable {
    public let label: String
    public let url: String

    public init(label: String, url: String) {
        self.label = label
        self.url = url
    }
}

/// PLAN.md 3.15: what the sponsor page shows. Read ONLY from the bundled secutg.json, for the same reason as the
/// distribution block: otherwise anyone repackaging the app could swap in their own payment codes. Every field is
/// optional and the whole block may be empty, in which case the sponsor entry does not appear at all.
public struct SponsorConfig: Equatable {
    public let note: String?
    public let qrs: [SponsorEntry]
    public let links: [SponsorLink]
    /// shown as copyable text rather than as a QR code
    public let addresses: [SponsorEntry]

    public init(note: String? = nil, qrs: [SponsorEntry] = [], links: [SponsorLink] = [], addresses: [SponsorEntry] = []) {
        self.note = note
        self.qrs = qrs
        self.links = links
        self.addresses = addresses
    }

    /// An unconfigured sponsor block hides the entry instead of opening an empty page.
    public var hasContent: Bool {
        if let note = note, !note.isEmpty { return true }
        return !qrs.isEmpty || !links.isEmpty || !addresses.isEmpty
    }

    public static let empty = SponsorConfig()
}

/// PLAN.md 3.21: the spectral watermark's settings. Both are optional and **no key means no watermark** — a mark
/// nobody holds the key to traces nothing, so drawing one would only cost contrast for nothing.
public struct WatermarkConfig: Equatable {
    /// 32 bytes; every spreading code is derived from it, so without it the pattern cannot be demodulated
    public let projectKey: [UInt8]
    /// deviation in 8-bit luminance, within `WatermarkCarrier.amplitudeMin ... amplitudeMax`
    public let amplitude: Double

    public init(projectKey: [UInt8], amplitude: Double) {
        self.projectKey = projectKey
        self.amplitude = amplitude
    }
}

/// Resolved, validated configuration. Immutable.
public struct SecutgConfig: Equatable {
    public let apiId: Int32
    public let apiHash: String
    public let appName: String
    public let crypto: CryptoConfig
    /// nil when the bundled file carries no `distribution` block (shown as "unofficial build")
    public let distribution: DistributionConfig?
    /// nil when the bundled file carries no `sponsor` block (the sponsor entry stays hidden)
    public let sponsor: SponsorConfig?
    /// nil when no `watermark_key` is configured — the conversation is then drawn without a watermark
    public let watermark: WatermarkConfig?

    public init(apiId: Int32, apiHash: String, appName: String, crypto: CryptoConfig, distribution: DistributionConfig? = nil, sponsor: SponsorConfig? = nil, watermark: WatermarkConfig? = nil) {
        self.apiId = apiId
        self.apiHash = apiHash
        self.appName = appName
        self.crypto = crypto
        self.distribution = distribution
        self.sponsor = sponsor
        self.watermark = watermark
    }

    /// The sponsor page and its two entry points appear only when the built-in block actually carries something.
    public var hasSponsorContent: Bool { return sponsor?.hasContent ?? false }
}

public enum SecutgConfigError: Error, Equatable, CustomStringConvertible {
    case invalidFile(String)
    case missingField(String)
    case invalidField(String)

    public var description: String {
        switch self {
        case .invalidFile(let m), .missingField(let m), .invalidField(let m): return m
        }
    }
}
