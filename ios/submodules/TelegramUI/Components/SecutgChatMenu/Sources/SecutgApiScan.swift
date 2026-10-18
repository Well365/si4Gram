import Foundation
import UIKit
import AVFoundation
import CoreImage
import Display
import AccountContext
import QrCodeUI
import SecutgCore
import TelegramCore

/// SECUTG (PLAN.md 3.40.4): how a new device takes in the `A1Q:` code another device shows — camera, the text
/// pasted, or a picture of the code. Every road ends in `ApiCredentialRules.parseA1Q`; anything it refuses is
/// `SecutgApiScanBad`, anything it accepts is confirmed with `SecutgApiScanConfirm {id}` before it is saved.
enum SecutgApiScan {
    /// `context` is nil on the start-up gate (nobody is logged in yet, and the app's own `QrCodeScanScreen` needs an
    /// account), so the gate uses `SecutgCameraQrScanner` — the same AVFoundation QR reader, without the account.
    static func present(over controller: ViewController, context: AccountContext?, completion: @escaping (ApiCredentialRules.Credentials) -> Void) {
        let sheet = UIAlertController(title: SecutgL10n.string("SecutgApiSetupScan"), message: nil, preferredStyle: .alert)
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgScan"), style: .default, handler: { [weak controller] _ in
            guard let controller else { return }
            scanWithCamera(over: controller, context: context, completion: completion)
        }))
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgApiPasteLabel"), style: .default, handler: { [weak controller] _ in
            guard let controller else { return }
            promptPaste(over: controller, completion: completion)
        }))
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgApiScanImage"), style: .default, handler: { [weak controller] _ in
            guard let controller else { return }
            pickImage(over: controller, completion: completion)
        }))
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        SecutgChatMenu.presentSystem(sheet, over: controller)
    }

    /// The parse-and-confirm step every road shares.
    static func handle(text: String?, over controller: ViewController, completion: @escaping (ApiCredentialRules.Credentials) -> Void) {
        guard let text, let credentials = ApiCredentialRules.parseA1Q(text) else {
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgApiScanBad"))
            return
        }
        let confirm = UIAlertController(title: nil, message: SecutgL10n.string("SecutgApiScanConfirm", ["id": String(credentials.apiId)]), preferredStyle: .alert)
        confirm.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        confirm.addAction(UIAlertAction(title: SecutgL10n.string("SecutgOk"), style: .default, handler: { _ in
            completion(credentials)
        }))
        SecutgChatMenu.presentSystem(confirm, over: controller)
    }

    private static func scanWithCamera(over controller: ViewController, context: AccountContext?, completion: @escaping (ApiCredentialRules.Credentials) -> Void) {
        if let context {
            // Logged in: the app's own scanner, the one the quick share (3.39) already uses.
            let scanner = QrCodeScanScreen(context: context, subject: .custom(info: SecutgL10n.string("SecutgApiSetupScan")))
            var handled = false
            scanner.completion = { [weak controller, weak scanner] code in
                guard !handled, let code else { return }
                handled = true
                scanner?.dismissAnimated()
                guard let controller else { return }
                handle(text: code, over: controller, completion: completion)
            }
            controller.push(scanner)
            return
        }
        let scanner = SecutgCameraQrScanner { [weak controller] code in
            guard let controller else { return }
            handle(text: code, over: controller, completion: completion)
        }
        scanner.modalPresentationStyle = .fullScreen
        SecutgTransfer.presentSystem(scanner, over: controller)
    }

    private static func promptPaste(over controller: ViewController, completion: @escaping (ApiCredentialRules.Credentials) -> Void) {
        let alert = UIAlertController(title: SecutgL10n.string("SecutgApiPasteLabel"), message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "A1Q:…"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            if let pasted = UIPasteboard.general.string, ApiCredentialRules.looksLikeA1Q(pasted) {
                field.text = pasted
            }
        }
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgOk"), style: .default, handler: { [weak controller, weak alert] _ in
            guard let controller else { return }
            handle(text: alert?.textFields?.first?.text, over: controller, completion: completion)
        }))
        SecutgChatMenu.presentSystem(alert, over: controller)
    }

    private static var imageDelegate: SecutgQrImagePickerDelegate?

    private static func pickImage(over controller: ViewController, completion: @escaping (ApiCredentialRules.Credentials) -> Void) {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        let delegate = SecutgQrImagePickerDelegate { [weak controller] image in
            imageDelegate = nil
            guard let controller, let image else { return }
            handle(text: decodeQr(image), over: controller, completion: completion)
        }
        imageDelegate = delegate
        picker.delegate = delegate
        SecutgTransfer.presentSystem(picker, over: controller)
    }

    /// The first QR in the picture that looks like an A1Q code, else the first QR at all (so a wrong code is
    /// named as such rather than as "nothing found").
    static func decodeQr(_ image: UIImage) -> String? {
        guard let ciImage = CIImage(image: image),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return nil }
        let messages = detector.features(in: ciImage).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        return messages.first(where: ApiCredentialRules.looksLikeA1Q) ?? messages.first
    }
}

private final class SecutgQrImagePickerDelegate: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let done: (UIImage?) -> Void

    init(done: @escaping (UIImage?) -> Void) {
        self.done = done
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        let image = info[.originalImage] as? UIImage
        picker.dismiss(animated: true) { self.done(image) }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true) { self.done(nil) }
    }
}

/// The metadata delegate, kept off the view controller so the AVFoundation callback never has to cross into a
/// main-actor class (the same shape as `FilePickerDelegate`). Delivers on the main queue, as configured below.
private final class SecutgQrMetadataDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    private let found: (String) -> Void

    init(found: @escaping (String) -> Void) {
        self.found = found
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let code = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        found(code)
    }
}

/// A plain AVFoundation QR reader for the start-up gate, where no account exists for `QrCodeScanScreen`. Reads the
/// first QR code it sees, closes, and hands the text on. Camera permission is the app's existing camera entry.
final class SecutgCameraQrScanner: UIViewController {
    private let session = AVCaptureSession()
    private let completion: (String) -> Void
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var metadataDelegate: SecutgQrMetadataDelegate?
    private var isDone = false
    private let closeButton = UIButton(type: .system)

    init(completion: @escaping (String) -> Void) {
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        closeButton.setTitle(SecutgL10n.string("SecutgScanStop"), for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted { self.startSession() } else { self.dismiss(animated: true) }
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        closeButton.frame = CGRect(x: 20.0, y: view.bounds.height - view.safeAreaInsets.bottom - 64.0, width: view.bounds.width - 40.0, height: 44.0)
    }

    private func startSession() {
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            dismiss(animated: true)
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            dismiss(animated: true)
            return
        }
        session.addOutput(output)
        let delegate = SecutgQrMetadataDelegate(found: { [weak self] code in
            self?.found(code)
        })
        metadataDelegate = delegate
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    private func found(_ code: String) {
        guard !isDone else { return }
        isDone = true
        session.stopRunning()
        let completion = self.completion
        dismiss(animated: true) { completion(code) }
    }

    @objc private func closeTapped() {
        isDone = true
        session.stopRunning()
        dismiss(animated: true)
    }
}
