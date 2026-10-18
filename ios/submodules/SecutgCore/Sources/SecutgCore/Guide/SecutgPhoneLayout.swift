import Foundation

/// Lays a guide scene out as a phone screen (PLAN.md 3.15). Pure and resolution-independent: the output is a list of
/// primitives in a 200x410 box, which every client's renderer draws with its own toolkit. Keeping the arithmetic here
/// rather than in the view is what lets the five clients show the same picture from the same data — this file is a
/// literal port of `src/secutg/ui/phone/layout.ts` in the Web client, constant for constant.
public enum SecutgPhoneLayout {
    public static let phoneWidth: Double = 200
    public static let phoneHeight: Double = 410

    static let screen = (x: 5.0, y: 5.0, w: 190.0, h: 400.0, r: 23.0)
    static let contentTop: Double = 72
    static let contentBottom: Double = 388
    static let side: Double = 16
    static let inputHeight: Double = 32
    static let bubbleMax: Double = 130
    static let bodySize: Double = 7.5

    // MARK: - text measuring

    /// Falls back to English, the same rule the string tables use.
    public static func pick(_ text: SecutgGuideText?, _ lang: String) -> String {
        guard let text = text else { return "" }
        if let value = text[lang], !value.isEmpty { return value }
        return text["en"] ?? ""
    }

    /// Rough advance width: CJK and emoji are about twice as wide as latin at the same size.
    static func charWidth(_ code: UInt32, _ size: Double) -> Double {
        if code >= 0x1F000 || (code >= 0x2190 && code <= 0x2BFF) { return size * 1.15 }
        if code >= 0x2E80 { return size }
        return size * 0.56
    }

    public static func textWidth(_ text: String, _ size: Double) -> Double {
        var total = 0.0
        for scalar in text.unicodeScalars { total += charWidth(scalar.value, size) }
        return total
    }

    /// Breaks at spaces where there are any, and anywhere in CJK runs, which have none.
    public static func wrapText(_ text: String, _ maxWidth: Double, _ size: Double) -> [String] {
        var lines: [String] = []
        var line: [Unicode.Scalar] = []
        var width = 0.0

        func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars)
            return String(view)
        }
        func flush() {
            if !line.isEmpty { lines.append(string(line[...])) }
            line = []
            width = 0
        }

        for scalar in text.unicodeScalars {
            let cw = charWidth(scalar.value, size)
            if width + cw > maxWidth && !line.isEmpty {
                let space = line.lastIndex(of: " ")
                // Only rewind to a space when it is not at the very start of the line, and only for latin-ish
                // incoming characters — a CJK run has no spaces to rewind to and breaks anywhere.
                if let space = space, space > 0, scalar.value >= 0x20, scalar.value <= 0x2E7F {
                    let carry = Array(line[(space + 1)...])
                    lines.append(string(line[0..<space]))
                    line = carry
                    width = textWidth(string(carry[...]), size)
                } else {
                    flush()
                }
            }
            line.append(scalar)
            width += cw
        }
        flush()
        return lines
    }

    // MARK: - chrome

    private struct Cursor {
        var y: Double
        var out: [PhonePrim]

        mutating func row(_ height: Double) -> Double {
            let top = y
            y += height
            return top
        }
    }

    private static func drawShell(_ out: inout [PhonePrim]) {
        out.append(.rect(PhoneRect(x: 0, y: 0, w: phoneWidth, h: phoneHeight, r: 27, fill: .bezel)))
        out.append(.rect(PhoneRect(x: screen.x, y: screen.y, w: screen.w, h: screen.h, r: screen.r, fill: .bg)))
    }

    private static func drawStatusBar(_ out: inout [PhonePrim]) {
        out.append(.rect(PhoneRect(x: 74, y: 11, w: 52, h: 12, r: 6, fill: .bezel)))
        out.append(.text(PhoneText(x: 18, y: 21, text: "15:04", size: 7.5, fill: .text)))
        out.append(.text(PhoneText(x: 182, y: 21, text: "▮▮ ⌁", size: 7.5, fill: .text, anchor: .end)))
        out.append(.rect(PhoneRect(x: 72, y: 393, w: 56, h: 3, r: 1.5, fill: .dim, opacity: 0.5)))
    }

    private static let lockGlyph: [String: String] = ["on": "🔒", "off": "🔓", "warn": "⚠️"]

    private static func drawHeader(_ out: inout [PhonePrim], _ scene: SecutgScene, _ lang: String) {
        out.append(.rect(PhoneRect(x: 5, y: 28, w: 190, h: 34, fill: .bg2)))
        out.append(.line(PhoneLine(x1: 5, y1: 62, x2: 195, y2: 62, stroke: .border)))
        out.append(.text(PhoneText(x: 16, y: 50, text: "‹", size: 11, fill: .primary)))
        let title = pick(scene.title, lang)
        let subtitle = pick(scene.subtitle, lang)
        if scene.chrome == "page" {
            out.append(.text(PhoneText(x: 100, y: 50, text: title, size: 9, fill: .text, anchor: .middle, bold: true)))
            return
        }
        out.append(.circle(PhoneCircle(cx: 34, cy: 45, r: 9, fill: .primary)))
        out.append(.text(PhoneText(x: 50, y: subtitle.isEmpty ? 48 : 43, text: title, size: 9, fill: .text)))
        if !subtitle.isEmpty {
            out.append(.text(PhoneText(x: 50, y: 53, text: subtitle, size: 7, fill: .dim)))
        }
        guard let lock = scene.lock, lock != "none" else { return }
        out.append(.circle(PhoneCircle(cx: 176, cy: 45, r: 11, fill: lock == "on" ? .green : (lock == "warn" ? .warn : .dim))))
        out.append(.text(PhoneText(x: 176, y: 49, text: lockGlyph[lock] ?? "", size: 9, fill: .paper, anchor: .middle)))
    }

    private static func drawInputBar(_ out: inout [PhonePrim], _ placeholder: String) {
        let top = contentBottom - inputHeight
        out.append(.line(PhoneLine(x1: 5, y1: top, x2: 195, y2: top, stroke: .border)))
        out.append(.rect(PhoneRect(x: 14, y: top + 8, w: 146, h: 18, r: 9, fill: .bg2)))
        out.append(.text(PhoneText(x: 24, y: top + 20, text: placeholder, size: 7.5, fill: .dim)))
        out.append(.circle(PhoneCircle(cx: 176, cy: top + 17, r: 9, fill: .primary)))
    }

    // MARK: - items

    private static func bubble(_ cursor: inout Cursor, _ text: String, own: Bool, warn: Bool) {
        let lines = wrapText(text, bubbleMax, bodySize)
        let width = lines.reduce(24.0, { max($0, textWidth($1, bodySize)) }) + 20
        let height = Double(lines.count) * 11 + 9
        let top = cursor.row(height + 6)
        let left = own ? 186 - width : side - 2
        cursor.out.append(.rect(PhoneRect(x: left, y: top, w: width, h: height, r: 9, fill: own ? .green : .bg2, opacity: own ? 0.18 : 1)))
        for (i, line) in lines.enumerated() {
            cursor.out.append(.text(PhoneText(x: left + 10, y: top + 13 + Double(i) * 11, text: line, size: bodySize, fill: warn ? .error : .text)))
        }
    }

    private static func paragraph(_ cursor: inout Cursor, _ text: String, _ style: String?) {
        let strong = style == "strong"
        let size = strong ? 9.0 : bodySize
        let lines = wrapText(text, 190 - side * 2, size)
        let top = cursor.row(Double(lines.count) * (size + 3.5) + 6)
        let fill: PhoneColor = style == "danger" ? .error : .text
        for (i, line) in lines.enumerated() {
            cursor.out.append(.text(PhoneText(
                x: strong ? 100 : side,
                y: top + size + Double(i) * (size + 3.5),
                text: line,
                size: size,
                fill: strong ? .text : fill,
                anchor: strong ? .middle : .start,
                bold: strong
            )))
        }
    }

    private static func settingsRow(_ cursor: inout Cursor, _ label: String, _ value: String, _ style: String?) {
        let top = cursor.row(24)
        if style == "hl" || style == "warn" {
            cursor.out.append(.rect(PhoneRect(x: 12, y: top, w: 176, h: 22, r: 7, fill: style == "warn" ? .warn : .green, opacity: 0.16)))
        }
        cursor.out.append(.text(PhoneText(x: 20, y: top + 14, text: label, size: 8.5, fill: .text)))
        if !value.isEmpty {
            cursor.out.append(.text(PhoneText(
                x: 180,
                y: top + 14,
                text: value,
                size: 8,
                fill: style == "warn" ? .warn : (style == "hl" ? .green : .dim),
                anchor: .end
            )))
        }
        cursor.out.append(.line(PhoneLine(x1: 20, y1: top + 23, x2: 180, y2: top + 23, stroke: .border)))
    }

    private static func menuItem(_ cursor: inout Cursor, _ text: String, _ style: String?, _ left: Double, _ right: Double) {
        if style == "caption" {
            let top = cursor.row(18)
            cursor.out.append(.text(PhoneText(x: (left + right) / 2, y: top + 11, text: text, size: 7.5, fill: .dim, anchor: .middle)))
            cursor.out.append(.line(PhoneLine(x1: left, y1: top + 17, x2: right, y2: top + 17, stroke: .border)))
            return
        }
        let lines = wrapText(text, right - left - 16, 8.5)
        let height = Double(lines.count) * 11 + 11
        let top = cursor.row(height)
        if style == "hl" || style == "warn" {
            cursor.out.append(.rect(PhoneRect(x: left + 2, y: top + 1, w: right - left - 4, h: height - 3, r: 8, fill: style == "warn" ? .warn : .green, opacity: 0.16)))
        }
        let fill: PhoneColor = style == "danger" ? .error : (style == "warn" ? .warn : (style == "hl" ? .green : .primary))
        for (i, line) in lines.enumerated() {
            cursor.out.append(.text(PhoneText(x: (left + right) / 2, y: top + 13 + Double(i) * 11, text: line, size: 8.5, fill: fill, anchor: .middle)))
        }
        cursor.out.append(.line(PhoneLine(x1: left, y1: top + height - 1, x2: right, y2: top + height - 1, stroke: .border)))
    }

    private static func pill(_ cursor: inout Cursor, _ text: String, _ style: String?, _ left: Double, _ right: Double) {
        let top = cursor.row(26)
        let width = right - left - 8
        if style == "primary" {
            cursor.out.append(.rect(PhoneRect(x: left + 4, y: top, w: width, h: 20, r: 10, fill: .primary)))
        }
        cursor.out.append(.text(PhoneText(
            x: (left + right) / 2,
            y: top + 13,
            text: text,
            size: 8.5,
            fill: style == "primary" ? .paper : (style == "danger" ? .error : .primary),
            anchor: .middle,
            bold: style == "primary"
        )))
    }

    private static func codeBox(_ cursor: inout Cursor, _ text: String, _ left: Double, _ right: Double) {
        let top = cursor.row(30)
        cursor.out.append(.rect(PhoneRect(x: left + 8, y: top, w: right - left - 16, h: 24, r: 7, fill: .green, opacity: 0.16)))
        cursor.out.append(.text(PhoneText(x: (left + right) / 2, y: top + 16, text: text, size: 9, fill: .green, anchor: .middle, mono: true)))
    }

    private static let qrBlocks: [(Double, Double, Double, Double)] = [
        (8, 8, 22, 22), (66, 8, 22, 22), (8, 66, 22, 22),
        (40, 28, 12, 12), (58, 46, 12, 12), (40, 64, 12, 12), (74, 64, 12, 12),
    ]

    private static func qrBox(_ cursor: inout Cursor) {
        let size = 96.0
        let top = cursor.row(size + 10)
        let left = 100 - size / 2
        cursor.out.append(.rect(PhoneRect(x: left, y: top, w: size, h: size, r: 8, fill: .paper, stroke: .border)))
        for (bx, by, bw, bh) in qrBlocks {
            cursor.out.append(.rect(PhoneRect(x: left + bx, y: top + by, w: bw, h: bh, fill: .ink)))
        }
    }

    private static func drawItems(_ cursor: inout Cursor, _ items: [SecutgSceneItem], _ lang: String, _ left: Double, _ right: Double) {
        for entry in items {
            let text = pick(entry.t, lang)
            switch entry.k {
            case "in":
                bubble(&cursor, text, own: false, warn: entry.style == "warn")
            case "out":
                bubble(&cursor, text, own: true, warn: entry.style == "warn")
            case "service":
                let top = cursor.row(18)
                cursor.out.append(.text(PhoneText(x: 100, y: top + 11, text: text, size: 7.5, fill: .dim, anchor: .middle)))
            case "body":
                paragraph(&cursor, text, entry.style)
            case "row":
                settingsRow(&cursor, text, pick(entry.v, lang), entry.style)
            case "item":
                menuItem(&cursor, text, entry.style, left, right)
            case "button":
                pill(&cursor, text, entry.style, left, right)
            case "code":
                codeBox(&cursor, text, left, right)
            case "qr":
                qrBox(&cursor)
            default:
                break
            }
        }
    }

    /// Height the items need, so a sheet or dialog can be sized before anything is drawn.
    private static func measure(_ items: [SecutgSceneItem], _ lang: String, _ left: Double, _ right: Double) -> Double {
        var probe = Cursor(y: 0, out: [])
        drawItems(&probe, items, lang, left, right)
        return probe.y
    }

    public static func layoutScene(_ scene: SecutgScene, lang: String, inputPlaceholder: String) -> [PhonePrim] {
        var out: [PhonePrim] = []
        drawShell(&out)
        drawHeader(&out, scene, lang)

        let overlay = scene.sheet != "none"
        let hasInput = scene.items.contains(where: { $0.k == "input" })
        let items = scene.items.filter({ $0.k != "input" })

        if overlay {
            // Blank bubbles behind the dim, so the sheet reads as sitting on top of a real screen
            out.append(.rect(PhoneRect(x: 14, y: contentTop + 8, w: 104, h: 20, r: 9, fill: .bg2)))
            out.append(.rect(PhoneRect(x: 88, y: contentTop + 36, w: 98, h: 20, r: 9, fill: .green, opacity: 0.18)))
            out.append(.rect(PhoneRect(x: screen.x, y: screen.y, w: screen.w, h: screen.h, r: screen.r, fill: .bezel, opacity: 0.45)))
        }

        if scene.sheet == "dialog" {
            let left = 22.0
            let right = 178.0
            let height = measure(items, lang, left, right) + 22
            let top = max(contentTop, (contentBottom + contentTop) / 2 - height / 2)
            out.append(.rect(PhoneRect(x: left, y: top, w: right - left, h: height, r: 14, fill: .bg, stroke: .border)))
            var cursor = Cursor(y: top + 12, out: out)
            drawItems(&cursor, items, lang, left + 6, right - 6)
            out = cursor.out
            drawStatusBar(&out)
            return out
        }

        if scene.sheet == "sheet" {
            let left = 12.0
            let right = 188.0
            let height = measure(items, lang, left, right) + 16
            let top = max(contentTop, contentBottom - 6 - height)
            out.append(.rect(PhoneRect(x: left, y: top, w: right - left, h: height, r: 14, fill: .bg, stroke: .border)))
            var cursor = Cursor(y: top + 10, out: out)
            drawItems(&cursor, items, lang, left, right)
            out = cursor.out
            drawStatusBar(&out)
            return out
        }

        var cursor = Cursor(y: contentTop, out: out)
        drawItems(&cursor, items, lang, 12, 188)
        out = cursor.out
        if hasInput { drawInputBar(&out, inputPlaceholder) }
        drawStatusBar(&out)
        return out
    }
}
