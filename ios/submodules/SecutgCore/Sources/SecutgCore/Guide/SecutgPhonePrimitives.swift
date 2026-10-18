import Foundation

/// The colour tokens a phone illustration uses. The renderer maps them onto the presentation theme so the picture
/// follows day / night; `bezel`, `paper`, `ink` and `warn` are fixed, because a phone body is dark and paper is white
/// whatever the app theme is.
public enum PhoneColor: String, Equatable, CaseIterable {
    case bezel, bg, bg2, text, dim, border, primary, green, error, warn, paper, ink
}

public enum PhoneTextAnchor: String, Equatable {
    case start, middle, end
}

public struct PhoneRect: Equatable {
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double
    public let r: Double?
    public let fill: PhoneColor
    public let opacity: Double?
    public let stroke: PhoneColor?

    public init(x: Double, y: Double, w: Double, h: Double, r: Double? = nil, fill: PhoneColor, opacity: Double? = nil, stroke: PhoneColor? = nil) {
        self.x = x; self.y = y; self.w = w; self.h = h
        self.r = r; self.fill = fill; self.opacity = opacity; self.stroke = stroke
    }
}

public struct PhoneText: Equatable {
    public let x: Double
    /// baseline, as in SVG
    public let y: Double
    public let text: String
    public let size: Double
    public let fill: PhoneColor
    public let anchor: PhoneTextAnchor
    public let bold: Bool
    public let mono: Bool

    public init(x: Double, y: Double, text: String, size: Double, fill: PhoneColor, anchor: PhoneTextAnchor = .start, bold: Bool = false, mono: Bool = false) {
        self.x = x; self.y = y; self.text = text; self.size = size
        self.fill = fill; self.anchor = anchor; self.bold = bold; self.mono = mono
    }
}

public struct PhoneCircle: Equatable {
    public let cx: Double
    public let cy: Double
    public let r: Double
    public let fill: PhoneColor
    public let opacity: Double?

    public init(cx: Double, cy: Double, r: Double, fill: PhoneColor, opacity: Double? = nil) {
        self.cx = cx; self.cy = cy; self.r = r; self.fill = fill; self.opacity = opacity
    }
}

public struct PhoneLine: Equatable {
    public let x1: Double
    public let y1: Double
    public let x2: Double
    public let y2: Double
    public let stroke: PhoneColor

    public init(x1: Double, y1: Double, x2: Double, y2: Double, stroke: PhoneColor) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2; self.stroke = stroke
    }
}

public enum PhonePrim: Equatable {
    case rect(PhoneRect)
    case text(PhoneText)
    case circle(PhoneCircle)
    case line(PhoneLine)
}
