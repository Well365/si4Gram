import Foundation
import UIKit
import Display
import TelegramPresentationData
import SecutgCore

/// SECUTG: draws one guide illustration (PLAN.md 3.15). All of the arithmetic lives in `SecutgPhoneLayout` inside
/// SecutgCore, so this view only maps the colour tokens onto the presentation theme and paints the primitives with
/// Core Graphics, scaled from the 200x410 design box to whatever size the layout gives it.
public final class SecutgPhoneScreenView: UIView {
    private var prims: [PhonePrim] = []
    private var palette: [PhoneColor: UIColor] = [:]

    public override init(frame: CGRect) {
        super.init(frame: frame)
        self.backgroundColor = .clear
        self.isOpaque = false
        self.contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The design box, so a container can reserve the right aspect ratio.
    public static let designSize = CGSize(width: SecutgPhoneLayout.phoneWidth, height: SecutgPhoneLayout.phoneHeight)

    public func update(scene: SecutgScene, lang: String, inputPlaceholder: String, theme: PresentationTheme) {
        self.prims = SecutgPhoneLayout.layoutScene(scene, lang: lang, inputPlaceholder: inputPlaceholder)
        self.palette = SecutgPhoneScreenView.palette(theme: theme)
        self.setNeedsDisplay()
    }

    /// The tokens that have a theme equivalent follow day / night; a phone body, paper and ink do not.
    static func palette(theme: PresentationTheme) -> [PhoneColor: UIColor] {
        return [
            .bezel: UIColor(rgb: 0x2a2d33),
            .bg: theme.list.plainBackgroundColor,
            // Must contrast with `bg`: it is the incoming bubble and the chat header band, and
            // `itemBlocksBackgroundColor` is the same white as `plainBackgroundColor` in the day theme
            .bg2: theme.list.blocksBackgroundColor,
            .text: theme.list.itemPrimaryTextColor,
            .dim: theme.list.itemSecondaryTextColor,
            .border: theme.list.itemBlocksSeparatorColor,
            .primary: theme.list.itemAccentColor,
            .green: theme.list.itemCheckColors.fillColor,
            .error: theme.list.itemDestructiveColor,
            .warn: UIColor(rgb: 0xc08a2e),
            .paper: UIColor(rgb: 0xffffff),
            .ink: UIColor(rgb: 0x16181c),
        ]
    }

    private func color(_ token: PhoneColor, _ opacity: Double?) -> UIColor {
        let base = palette[token] ?? UIColor.gray
        guard let opacity = opacity, opacity < 1.0 else { return base }
        return base.withAlphaComponent(CGFloat(opacity))
    }

    private static func font(size: CGFloat, bold: Bool, mono: Bool) -> UIFont {
        if mono {
            return UIFont(name: bold ? "Menlo-Bold" : "Menlo", size: size) ?? UIFont.monospacedDigitSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
        }
        return UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    public override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), !prims.isEmpty else { return }
        let design = SecutgPhoneScreenView.designSize
        let scale = min(bounds.width / design.width, bounds.height / design.height)
        guard scale > 0.0 else { return }
        context.saveGState()
        context.translateBy(x: (bounds.width - design.width * scale) / 2.0, y: (bounds.height - design.height * scale) / 2.0)
        context.scaleBy(x: scale, y: scale)

        for prim in prims {
            switch prim {
            case let .rect(item):
                let frame = CGRect(x: item.x, y: item.y, width: item.w, height: item.h)
                let path = item.r.map { UIBezierPath(roundedRect: frame, cornerRadius: CGFloat($0)) } ?? UIBezierPath(rect: frame)
                color(item.fill, item.opacity).setFill()
                path.fill()
                if let stroke = item.stroke {
                    color(stroke, nil).setStroke()
                    path.lineWidth = 0.5
                    path.stroke()
                }
            case let .circle(item):
                let frame = CGRect(x: item.cx - item.r, y: item.cy - item.r, width: item.r * 2.0, height: item.r * 2.0)
                color(item.fill, item.opacity).setFill()
                UIBezierPath(ovalIn: frame).fill()
            case let .line(item):
                let path = UIBezierPath()
                path.move(to: CGPoint(x: item.x1, y: item.y1))
                path.addLine(to: CGPoint(x: item.x2, y: item.y2))
                path.lineWidth = 0.5
                color(item.stroke, nil).setStroke()
                path.stroke()
            case let .text(item):
                let font = SecutgPhoneScreenView.font(size: CGFloat(item.size), bold: item.bold, mono: item.mono)
                let string = NSAttributedString(string: item.text, attributes: [
                    .font: font,
                    .foregroundColor: color(item.fill, nil),
                ])
                let width = string.size().width
                let x: CGFloat
                switch item.anchor {
                case .start: x = CGFloat(item.x)
                case .middle: x = CGFloat(item.x) - width / 2.0
                case .end: x = CGFloat(item.x) - width
                }
                // The layout gives an SVG baseline; UIKit draws from the top of the line box.
                string.draw(at: CGPoint(x: x, y: CGFloat(item.y) - font.ascender))
            }
        }
        context.restoreGState()
    }
}
