import Foundation
import UIKit
import CoreImage
import AsyncDisplayKit
import Display
import TelegramCore

/// SECUTG: full-screen QR of a `secutg://key?…` payload for offline key hand-over, with a copy button.
/// Renders through CoreImage so it has no dependency on the upstream QR pipeline. Strings come from `SecutgL10n`.
public final class SecutgKeyQrController: ViewController {
    private let payload: String
    private let heading: String
    private let imageView = UIImageView()
    private let label = UILabel()
    private let copyButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    public init(payload: String, title: String) {
        self.payload = payload
        self.heading = title
        super.init(navigationBarPresentationData: nil)
        self.statusBar.statusBarStyle = .Ignore
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = .white
        self.displayNodeDidLoad()
        let view = self.displayNode.view

        imageView.contentMode = .scaleAspectFit
        imageView.image = SecutgKeyQrController.render(payload)
        label.text = heading
        label.font = UIFont.boldSystemFont(ofSize: 17)
        label.textColor = .black
        label.textAlignment = .center
        label.numberOfLines = 0
        copyButton.setTitle(SecutgL10n.string("SecutgCopyKeyText"), for: .normal)
        copyButton.titleLabel?.numberOfLines = 0
        copyButton.titleLabel?.textAlignment = .center
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        closeButton.setTitle(SecutgL10n.string("SecutgClose"), for: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        for sub in [imageView, label, copyButton, closeButton] { view.addSubview(sub) }
    }

    public override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let width = layout.size.width
        let side = min(width - 64, 320)
        label.frame = CGRect(x: 24, y: layout.safeInsets.top + 24, width: width - 48, height: 60)
        imageView.frame = CGRect(x: (width - side) / 2, y: label.frame.maxY + 16, width: side, height: side)
        copyButton.frame = CGRect(x: 24, y: imageView.frame.maxY + 24, width: width - 48, height: 64)
        closeButton.frame = CGRect(x: 24, y: copyButton.frame.maxY + 8, width: width - 48, height: 44)
    }

    @objc private func copyTapped() {
        UIPasteboard.general.string = payload
        copyButton.setTitle(SecutgL10n.string("SecutgClipboardHint"), for: .normal)
    }

    @objc private func closeTapped() {
        self.dismiss()
    }

    /// `correctionLevel` is "M" unless the caller's capacity rule picked another: a V2Q past 2331 bytes is "L", and
    /// asking CIQRCodeGenerator for M then returns nothing — a blank code page (PLAN.md 3.39.12 item 4).
    static func render(_ text: String, correctionLevel: String = "M") -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue(correctionLevel, forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        // SECUTG-HOOK (fix, 2026-10-02, PLAN.md 3.39.13): CIQRCodeGenerator draws a 1-module quiet zone; pad it to the
        // standard 4 in white so the code does not depend on what surrounds the image, and scale without smoothing.
        let pad: CGFloat = 3.0
        let canvas = CGRect(x: 0.0, y: 0.0, width: output.extent.width + 2.0 * pad, height: output.extent.height + 2.0 * pad)
        let padded = output.transformed(by: CGAffineTransform(translationX: pad, y: pad))
            .composited(over: CIImage(color: CIColor(red: 1.0, green: 1.0, blue: 1.0)).cropped(to: canvas))
        let scaled = padded.samplingNearest().transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
