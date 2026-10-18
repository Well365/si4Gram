import Foundation

/// The spatial layout of the watermark (PLAN.md 3.21.2), ported from Web A `src/secutg/watermark/carrier.ts`.
///
/// The pattern carries the identities themselves, spread across a tile by `WatermarkCodec`; this type owns only
/// where a chip lands on the screen. Keeping the two apart is what lets the renderer and a future extractor share
/// one definition of "which chip is this pixel in".
public enum WatermarkCarrier {
    /// Chips along one edge of a tile, so `tile * tile` chips carry the whole payload.
    ///
    /// 64 rather than 32, and the reason is measured. Every bit rides its own spreading code, so the codes have to
    /// be separable: at 32 (1024 chips) the load is 0.137 bits per chip and two bits come out wrong **however large
    /// the screenshot is** — repeating an identical tile scales the interference along with the signal, so area buys
    /// nothing against it. At 48 the errors reach zero; 64 (0.034 bits per chip) is that with room for noise.
    public static let tile = 64

    /// How many device pixels wide one chip is.
    ///
    /// Not 1, and also measured. Noise costs this scheme almost nothing but **downscaling** does: at one pixel per
    /// chip, halving an image averages neighbouring chips together and the pattern is gone. At two pixels per chip a
    /// 2x downscale maps one chip block to one pixel instead of averaging it away.
    public static let chipPixels = 2

    /// How many device pixels one tile spans. The pattern repeats on this period.
    public static let tilePixels = tile * chipPixels

    /// Default deviation in 8-bit luminance; `watermark_amplitude` in secutg.json overrides it.
    ///
    /// 1.5, not 2, and the reason is measured (PLAN.md 3.21.2). At 512 px and above the two are within one crop in
    /// twenty-eight of each other; below that 2 reads a little more often. The feature's whole premise is that it
    /// cannot be seen, so the knee of that curve is where the default sits.
    ///
    /// A two-zone scheme — low on the wallpaper, high inside bubbles — was measured and rejected: the decoder's
    /// inverse-variance weighting correctly treats text-filled bubbles as noise, so raising their amplitude from 1
    /// to 4 changed nothing at all. Detection lives on the wallpaper; bubbles are, for this purpose, dead.
    public static let amplitude: Double = 1.5

    /// The range `watermark_amplitude` is allowed to take. Beyond 4 it is visible on any flat colour.
    public static let amplitudeMin: Double = 0.5
    public static let amplitudeMax: Double = 4

    /// Roughly how much area a reading needs. One tile already carries every bit, so this is margin against
    /// compression and a partial first tile rather than a second copy of the payload.
    public static let minTiles = 2

    /// Which chip a device-pixel coordinate falls in, wrapping at the tile and never going negative.
    public static func chipIndex(_ coordinate: Int) -> Int {
        let wrapped = ((coordinate % tilePixels) + tilePixels) % tilePixels
        return wrapped / chipPixels
    }

    /// Luminance offset at a pixel. `x` and `y` are **device pixels in the conversation area's own coordinate
    /// space**, not relative to a bubble: the phase has to be continuous across messages, because a crop spanning
    /// two of them must hold one coherent field rather than two that cancel.
    public static func carrierAt(_ carrier: [Int8], x: Int, y: Int, amplitude: Double = amplitude) -> Double {
        return Double(carrier[chipIndex(y) * tile + chipIndex(x)]) * amplitude
    }

    /// One tile of the pattern as RGBA device pixels, ready to become a repeating image.
    ///
    /// Ported from Web A `render.ts`. The pattern is *added* to luminance, which ordinary alpha compositing cannot
    /// do: blending white at opacity `a` moves a pixel by `a * (255 - dst)`, so the same overlay that shifts a
    /// mid-tone wallpaper by 2 barely touches a near-white bubble, and the watermark would fade out exactly where
    /// the text is. Additive compositing (`CGBlendMode.plusLighter` on Apple platforms, `plus-lighter` on the web)
    /// adds instead of interpolating, so the shift is the same everywhere.
    ///
    /// Additive compositing can only add, so the pattern is biased: a `+1` chip paints `2 * amplitude` and a `-1`
    /// chip paints nothing, which is "+amplitude on average, ±amplitude around it". The constant part is invisible
    /// and costs nothing to detect — the extractor subtracts a local mean before it correlates.
    ///
    /// Alpha is fully opaque throughout: under additive compositing a transparent pixel adds nothing, which is
    /// exactly what a `-1` chip should do, so the sign lives in the colour and never in the alpha.
    public static func tileRGBA(_ carrier: [Int8], amplitude: Double = amplitude, alpha: UInt8 = 255) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: tilePixels * tilePixels * 4)
        data.withUnsafeMutableBytes { buffer in
            writeField(carrier, amplitude: amplitude, alpha: alpha,
                       into: buffer.baseAddress!, bytesPerRow: tilePixels * 4,
                       width: tilePixels, height: tilePixels, originX: 0, originY: 0)
        }
        return data
    }

    /// The 8-bit level a `+1` chip paints. Rounded, because the overlay is 8-bit: 1.5 paints as 0 / 3, which
    /// averages to the +1.5 asked for.
    public static func paintedLevel(amplitude: Double = amplitude) -> UInt8 {
        return UInt8(clamping: Int((amplitude * 2).rounded()))
    }

    /// Fills a whole RGBA8 area with the pattern, phase taken from `originX` / `originY` so that a region drawn on
    /// its own still lands on the conversation area's one continuous field.
    ///
    /// `alpha` selects how the caller intends to composite. 255 is the web's form, to be drawn with an explicit
    /// additive blend mode. **0 is the form Apple platforms need**: Core Animation composites layer contents with
    /// premultiplied source-over, `out = src + dst * (1 - srcAlpha)`, so a premultiplied pixel whose alpha is zero
    /// and whose colour is `level` adds exactly `level` — real addition, with no blend mode to negotiate. It also
    /// fails in the only acceptable direction: anything that insists on reading alpha 0 as "draw nothing" produces
    /// no watermark rather than the flat grey film that ordinary alpha blending would leave over the conversation.
    public static func writeField(_ carrier: [Int8], amplitude: Double = amplitude, alpha: UInt8,
                                  into destination: UnsafeMutableRawPointer, bytesPerRow: Int,
                                  width: Int, height: Int, originX: Int, originY: Int) {
        guard width > 0, height > 0 else { return }
        let level = paintedLevel(amplitude: amplitude)
        let bytes = destination.assumingMemoryBound(to: UInt8.self)
        // One row of chips is the whole repeating unit horizontally; build each distinct row once and copy it.
        var row = [UInt8](repeating: 0, count: width * 4)
        var builtRow = [Bool](repeating: false, count: tile)
        var rowCache = [[UInt8]](repeating: [], count: tile)
        for y in 0..<height {
            let chipY = chipIndex(originY + y)
            if !builtRow[chipY] {
                for x in 0..<width {
                    let chip = carrier[chipY * tile + chipIndex(originX + x)]
                    let value: UInt8 = chip > 0 ? level : 0
                    let at = x * 4
                    row[at] = value
                    row[at + 1] = value
                    row[at + 2] = value
                    row[at + 3] = alpha
                }
                rowCache[chipY] = row
                builtRow[chipY] = true
            }
            rowCache[chipY].withUnsafeBytes { source in
                (bytes + y * bytesPerRow).update(from: source.baseAddress!.assumingMemoryBound(to: UInt8.self), count: width * 4)
            }
        }
    }
}
