import Foundation
import UIKit
import Display
import TelegramCore

/// SECUTG (2026-10-08 user): the 🆘 and lock floating buttons can be dragged anywhere on their screen, and
/// the spot is remembered per screen — the same behaviour the Mac client got in 4e5b2a9 (Android:
/// `SecutgDraggable.java`).
///
/// The host still computes the default corner on every layout pass and hands it to `frame(default:…)`; with
/// nothing saved that frame is used unchanged, so 〔恢复默认位置〕 is simply "forget the saved spot". The spot
/// is stored as the button centre's fraction of the host's size, so a rotation or a split-view resize moves
/// it proportionally instead of pushing it off screen, and it is always clamped inside the safe area.
///
/// A tap is still a tap: the pan recognizer cancels the button's own touch once it starts, so letting go
/// after a drag never fires the wipe or opens the lock sheet. A long press offers the reset.
final class SecutgDraggable: NSObject {
    private static let prefix = "secutg.floating."

    private weak var button: UIButton?
    private weak var controller: ViewController?
    private var key = ""
    private var defaultFrame = CGRect.zero
    private var area = CGRect.zero
    private var hostSize = CGSize.zero
    private var startFrame = CGRect.zero
    private var dragging = false

    init(button: UIButton) {
        self.button = button
        super.init()
        button.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(self.panned(_:))))
        button.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(self.longPressed(_:))))
    }

    /// The frame to give the button on this layout pass; `key` names the screen so each keeps its own spot.
    func frame(default defaultFrame: CGRect, key: String, layout: ContainerViewLayout, controller: ViewController) -> CGRect {
        self.key = key
        self.controller = controller
        self.defaultFrame = defaultFrame
        self.hostSize = layout.size
        let top = layout.statusBarHeight ?? 0.0
        let bottom = max(layout.intrinsicInsets.bottom, layout.safeInsets.bottom)
        self.area = CGRect(x: layout.safeInsets.left, y: top,
                           width: max(0.0, layout.size.width - layout.safeInsets.left - layout.safeInsets.right),
                           height: max(0.0, layout.size.height - top - bottom))
        if self.dragging, let button = self.button {
            return button.frame
        }
        guard let saved = self.saved(), layout.size.width > 0.0, layout.size.height > 0.0 else {
            return defaultFrame
        }
        let size = defaultFrame.size
        return self.clamp(CGRect(x: saved.x * layout.size.width - size.width / 2.0,
                                 y: saved.y * layout.size.height - size.height / 2.0,
                                 width: size.width, height: size.height))
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard let button = self.button else { return }
        switch recognizer.state {
        case .began:
            self.dragging = true
            self.startFrame = button.frame
        case .changed:
            let t = recognizer.translation(in: button.superview)
            button.frame = self.clamp(self.startFrame.offsetBy(dx: t.x, dy: t.y))
        case .ended, .cancelled, .failed:
            self.dragging = false
            self.save(button.frame)
        default:
            break
        }
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let button = self.button, let controller = self.controller else { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgFloatingResetPosition"), style: .default, handler: { [weak self] _ in
            self?.reset()
        }))
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = button
            popover.sourceRect = button.bounds
        }
        SecutgChatMenu.presentSystem(sheet, over: controller)
    }

    private func reset() {
        UserDefaults.standard.removeObject(forKey: Self.prefix + self.key)
        self.button?.frame = self.defaultFrame
    }

    private func saved() -> CGPoint? {
        guard let pair = UserDefaults.standard.array(forKey: Self.prefix + self.key) as? [Double], pair.count == 2 else {
            return nil
        }
        return CGPoint(x: pair[0], y: pair[1])
    }

    private func save(_ frame: CGRect) {
        guard self.hostSize.width > 0.0, self.hostSize.height > 0.0, !self.key.isEmpty else { return }
        UserDefaults.standard.set([Double(frame.midX / self.hostSize.width), Double(frame.midY / self.hostSize.height)],
                                  forKey: Self.prefix + self.key)
    }

    private func clamp(_ frame: CGRect) -> CGRect {
        var out = frame
        out.origin.x = max(self.area.minX, min(self.area.maxX - frame.width, frame.origin.x))
        out.origin.y = max(self.area.minY, min(self.area.maxY - frame.height, frame.origin.y))
        return out
    }
}
