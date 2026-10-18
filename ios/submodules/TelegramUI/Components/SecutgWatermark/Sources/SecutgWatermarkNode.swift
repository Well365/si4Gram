import AsyncDisplayKit
import Foundation
import Postbox
import SecutgCore
import TelegramCore
import UIKit

/// SECUTG (PLAN.md 3.21): the spectral watermark drawn over the whole conversation area.
///
/// Everything that decides *what* the pattern says lives in `SecutgCore` (`WatermarkCodec` / `WatermarkCarrier`),
/// which the macOS client shares; this file only turns the resulting ±1 chips into pixels and hangs them over the
/// chat. Three properties of the drawing are load-bearing and none of them is cosmetic:
///
/// 1. **Device pixels, never logical ones.** A chip is two device pixels wide precisely so that a 2x downscale maps
///    one chip block onto one pixel instead of averaging neighbouring chips away. Drawing in points would let Retina
///    scaling smear the pattern before a screenshot is even taken, so the layer's contents are built at exactly
///    `size * scale` pixels with nearest-neighbour filtering and no resampling anywhere.
///
/// 2. **The phase belongs to the conversation area, not to the content.** The pattern is *not* restarted per bubble
///    and does not move with the scroll: a crop spanning two messages must hold one coherent field rather than two
///    unrelated ones that cancel. This node is a sibling of the history list, not a child of it, so its coordinate
///    system stands still while messages move through it.
///
/// 3. **The overlay adds, it does not blend.** Ordinary alpha compositing moves a pixel by `a * (255 - dst)`, so the
///    same overlay that shifts a mid-tone wallpaper by 2 barely touches a near-white bubble: the watermark would fade
///    out exactly where the text is. The reference implementation names this `mix-blend-mode: plus-lighter`; `CGBlendMode.plusLighter` is the same arithmetic, but a blend mode
///    only applies inside one `CGContext`, and the wallpaper, the bubbles and this overlay are separate layers
///    composited by Core Animation. So the addition is asked for twice, in the two forms a layer can ask:
///
///    - `compositingFilter = "plusL"` — Core Animation's own plus-lighter, the direct counterpart of the web's
///      `mix-blend-mode`.
///    - the contents are **premultiplied with alpha 0 and colour `level`**, which under plain premultiplied
///      source-over, `out = src + dst * (1 - srcAlpha)`, is also exactly `dst + level`.
///
///    Either one alone paints the right pattern, and — this is the point — a renderer that honours **neither** draws
///    *nothing*, because alpha is zero. That is the same rule the web client applies when a browser does not know
///    `plus-lighter`: no watermark is acceptable, a flat grey film over the conversation is not. An opaque tile would
///    have the opposite failure and is therefore not used, whatever it would cost in certainty.
///
///    What is verified offline: `CGBlendMode.plusLighter` against an opaque tile adds exactly `level` and clamps at
///    255, and Core **Graphics** discards the colour of an alpha-0 premultiplied pixel (drawing nothing) rather than
///    adding it. Core **Animation**'s compositor is a different rasteriser and is the one that matters here; which of
///    the two mechanisms above carries the pattern on a real screen has not been measured, because measuring it means
///    running the app. Both of its possible outcomes are safe; the one that must be checked on a real device is that
///    the pattern is painted at all.
public final class SecutgWatermarkNode: ASDisplayNode {
    private struct Rendered: Equatable {
        let viewerId: Int64
        let chatId: Int64
        let timeBucket: Int
        let widthPixels: Int
        let heightPixels: Int
        let level: UInt8
        let keyFingerprint: UInt64
    }

    /// A whole-screen field at 3x is a few megabytes; anything past this is a layout we do not believe in.
    private static let maximumPixels = 64 * 1024 * 1024

    private var rendered: Rendered?
    private var generation: Int = 0
    private var bucketTimer: SwiftSignalKitTimerBox?
    private var lastRequest: (accountPeerId: PeerId, chatPeerId: PeerId?, size: CGSize, scale: CGFloat)?

    override public init() {
        super.init()

        // Layer-backed: there is no view, so the overlay can never take a touch away from the conversation.
        self.isLayerBacked = true
        self.clipsToBounds = true
    }

    override public func didLoad() {
        super.didLoad()

        // Anchored at the origin at its own pixel size rather than stretched to the layer: a frame change that
        // arrives before the repaint must clip the field, never resample it into a different geometry.
        self.layer.contentsGravity = .topLeft
        self.layer.magnificationFilter = .nearest
        self.layer.minificationFilter = .nearest
        // Core Animation's plus-lighter. An unknown name is simply ignored, which the alpha-0 contents make safe.
        self.layer.compositingFilter = "plusL"
    }

    deinit {
        self.bucketTimer?.invalidate()
    }

    /// `frame` is the conversation area in the parent's coordinates: below the navigation bar, above the input
    /// panel, and covering the wallpaper, the bubbles and the empty space alike.
    public func update(accountPeerId: PeerId, chatPeerId: PeerId?, frame: CGRect, scale: CGFloat) {
        // Set outright rather than through the layout transition: an animated frame would resample the field
        // mid-flight, and the pattern is invisible anyway, so there is nothing for an animation to smooth.
        if self.frame != frame {
            self.frame = frame
        }
        self.lastRequest = (accountPeerId, chatPeerId, frame.size, scale)
        self.refresh()
    }

    private func refresh() {
        guard let request = self.lastRequest else { return }
        // SECUTG-HOOK (PLAN.md 3.53): an App Store build never creates the watermark layer at all.
        if SecutgStoreBuild.isEnabled {
            self.clear()
            return
        }
        // PLAN.md 3.21.1: no key means no watermark. A mark nobody holds the key to traces nothing, so drawing one
        // would only cost contrast for nothing.
        guard let config = SecutgConfigHolder.shared.config?.watermark, let chatPeerId = request.chatPeerId else {
            self.clear()
            return
        }
        let scale = max(1.0, request.scale)
        let widthPixels = Int((request.size.width * scale).rounded())
        let heightPixels = Int((request.size.height * scale).rounded())
        guard widthPixels > 0, heightPixels > 0, widthPixels * heightPixels <= Self.maximumPixels else {
            self.clear()
            return
        }
        guard let viewerId = SecutgWatermarkIdentity.watermarkId(ofUser: request.accountPeerId),
              let chatId = SecutgWatermarkIdentity.watermarkId(ofChat: chatPeerId) else {
            self.clear()
            return
        }

        let now = Int64(Date().timeIntervalSince1970)
        let timeBucket = WatermarkPayload.timeBucket(nowSeconds: now)
        self.scheduleBucketRefresh(after: now)

        let wanted = Rendered(viewerId: viewerId, chatId: chatId, timeBucket: timeBucket,
                              widthPixels: widthPixels, heightPixels: heightPixels,
                              level: WatermarkCarrier.paintedLevel(amplitude: config.amplitude),
                              keyFingerprint: SecutgWatermarkIdentity.fingerprint(config.projectKey))
        if self.rendered == wanted, self.layer.contents != nil {
            self.layer.contentsScale = scale
            return
        }

        self.generation += 1
        let generation = self.generation
        let fields = WatermarkCodec.Fields(viewerId: viewerId, chatId: chatId, timeBucket: timeBucket)
        let projectKey = config.projectKey
        let amplitude = config.amplitude
        // Filling a screen-sized buffer is a few milliseconds; it happens on a resize, a chat switch or a ten-minute
        // boundary, so it is kept off the main thread rather than made cheaper.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = SecutgWatermarkImage.make(projectKey: projectKey, fields: fields, amplitude: amplitude,
                                                  widthPixels: widthPixels, heightPixels: heightPixels)
            DispatchQueue.main.async {
                guard let strongSelf = self, strongSelf.generation == generation else { return }
                guard let image = image else {
                    strongSelf.clear()
                    return
                }
                strongSelf.layer.contentsScale = scale
                strongSelf.layer.contents = image
                strongSelf.rendered = wanted
            }
        }
    }

    private func clear() {
        self.generation += 1
        self.rendered = nil
        self.layer.contents = nil
        self.bucketTimer?.invalidate()
        self.bucketTimer = nil
    }

    /// The payload says *when the screen was looked at*, so a chat left open across a bucket boundary has to be
    /// repainted; nothing else in the layout would trigger it.
    private func scheduleBucketRefresh(after now: Int64) {
        guard self.bucketTimer == nil else { return }
        let period = Double(60 * WatermarkPayload.bucketMinutes)
        let remaining = period - Double(now).truncatingRemainder(dividingBy: period)
        self.bucketTimer = SwiftSignalKitTimerBox(timeout: max(1.0, remaining) + 0.5) { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.bucketTimer = nil
            strongSelf.refresh()
        }
    }
}

/// A one-shot main-thread timer, kept here so the node does not drag in a scheduler for one callback.
private final class SwiftSignalKitTimerBox {
    private var timer: Timer?

    init(timeout: Double, action: @escaping () -> Void) {
        self.timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in action() }
    }

    func invalidate() {
        self.timer?.invalidate()
        self.timer = nil
    }
}

/// Turning identities and peers into what the codec expects.
public enum SecutgWatermarkIdentity {
    /// The viewer is an account, so its id is the plain user id.
    public static func watermarkId(ofUser peerId: PeerId) -> Int64? {
        return Int64(SecutgAccountRuntime.userId(peerId))
    }

    /// The chat id in the format every client shares: `<id>` for users, `-<id>` for groups, `-100<id>` for channels
    /// (PLAN.md 3.21.1). Secret chats have no such id and are not watermarked.
    public static func watermarkId(ofChat peerId: PeerId) -> Int64? {
        guard peerId.namespace != Namespaces.Peer.SecretChat else { return nil }
        return Int64(SecutgAccountRuntime.chatKey(peerId))
    }

    /// Enough of the key to notice it changed, and never enough to be one.
    public static func fingerprint(_ key: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

/// The carrier as a `CGImage` in the premultiplied-additive form described on `SecutgWatermarkNode`.
enum SecutgWatermarkImage {
    static func make(projectKey: [UInt8], fields: WatermarkCodec.Fields, amplitude: Double,
                     widthPixels: Int, heightPixels: Int) -> CGImage? {
        guard let carrier = try? WatermarkCodec.carrier(projectKey: projectKey, fields: fields) else { return nil }
        let bytesPerRow = widthPixels * 4
        var pixels = Data(count: bytesPerRow * heightPixels)
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            // Alpha 0: Core Animation's premultiplied source-over then adds the colour outright, which is the
            // `plus-lighter` arithmetic the reference implementation relies on.
            WatermarkCarrier.writeField(carrier, amplitude: amplitude, alpha: 0, into: base, bytesPerRow: bytesPerRow,
                                        width: widthPixels, height: heightPixels, originX: 0, originY: 0)
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: widthPixels, height: heightPixels, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
