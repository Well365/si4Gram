import Foundation
import UIKit
import Postbox
import TelegramCore
import SwiftSignalKit
import AccountContext
import SecutgCore

/// Sending text or an image through a relay (PLAN.md 3.48.3 / 3.48.4): upload, build the `L1:` reference, then
/// hand it to the ordinary send path exactly like any other text message (PLAN.md 3.48.0 rule 4 — the relay
/// reference is what gets E1/E2-encrypted or sent plain, not the content itself). The existing media-sending
/// pipeline is never touched: an image sent through a relay is a text message whose text happens to be `L1:`.
public enum SecutgRelaySendFlow {
    public enum SendError: Error {
        case notConfigured
        case tooLarge
        case upload(RelayClientError)
        case encode
    }

    /// Re-encodes to JPEG, which drops EXIF (location, camera metadata) by construction — PLAN.md 3.48.2's
    /// "strip EXIF" setting, honoured here rather than in the picker so every image path goes through it.
    public static func stripExifJPEG(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return image.jpegData(compressionQuality: 0.92)
    }

    public static func sendText(context: AccountContext, peerId: PeerId, text: String, relay: RelayEndpoint, keepPolicy: RelayKeepPolicy, encrypt: Bool, completion: @escaping (Result<Void, SendError>) -> Void) {
        guard let data = text.data(using: .utf8) else { completion(.failure(.encode)); return }
        send(context: context, peerId: peerId, plaintext: data, mime: "text/plain;charset=utf-8", contentType: .text, relay: relay, keepPolicy: keepPolicy, encrypt: encrypt, completion: completion)
    }

    public static func sendImage(context: AccountContext, peerId: PeerId, imageData: Data, mime: String, relay: RelayEndpoint, keepPolicy: RelayKeepPolicy, encrypt: Bool, stripExif: Bool, completion: @escaping (Result<Void, SendError>) -> Void) {
        let payload: Data
        let outMime: String
        if stripExif, let stripped = stripExifJPEG(imageData) {
            payload = stripped
            outMime = "image/jpeg"
        } else {
            payload = imageData
            outMime = mime
        }
        send(context: context, peerId: peerId, plaintext: payload, mime: outMime, contentType: .image, relay: relay, keepPolicy: keepPolicy, encrypt: encrypt, completion: completion)
    }

    private static func send(context: AccountContext, peerId: PeerId, plaintext: Data, mime: String, contentType: RelayContentType, relay: RelayEndpoint, keepPolicy: RelayKeepPolicy, encrypt: Bool, completion: @escaping (Result<Void, SendError>) -> Void) {
        guard RelayHost.classify(relay.urlString) != nil else { completion(.failure(.notConfigured)); return }
        guard !RelaySend.exceedsLimit(sizeBytes: plaintext.count, contentType: contentType, info: nil) else {
            completion(.failure(.tooLarge))
            return
        }
        let prepared: RelaySend.PreparedUpload
        do {
            prepared = try RelaySend.prepareUpload(plaintext: plaintext, originalMime: mime, encrypt: encrypt)
        } catch {
            completion(.failure(.encode))
            return
        }
        SecutgRelayRuntime.shared.client.upload(
            baseURL: relay.urlString, token: relay.token, contentType: contentType, mime: prepared.uploadMime,
            maxReads: keepPolicy.maxReads, ttlSeconds: keepPolicy.ttlSeconds, body: prepared.body
        ) { result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async { completion(.failure(.upload(error))) }
            case .success(let upload):
                let ref = RelaySend.buildReference(relayURL: relay.urlString, uploadResult: upload, contentType: contentType, originalMime: mime, sizeBytes: plaintext.count, contentKey: prepared.contentKey)
                let wire = RelayL1.encode(ref)
                enqueueAndRecord(context: context, peerId: peerId, wire: wire, relayURL: relay.urlString, uploadResult: upload, contentType: contentType, keepPolicy: keepPolicy, mime: mime, plaintext: plaintext)
                DispatchQueue.main.async { completion(.success(())) }
            }
        }
    }

    /// PLAN.md 3.48.3's normal enqueue path, link preview off, then PLAN.md 3.48.4/3.48.7 §2's bookkeeping:
    /// the sent-item record (for withdraw) and the sender's own local copy (shown as itself immediately, no
    /// fetch needed).
    private static func enqueueAndRecord(context: AccountContext, peerId: PeerId, wire: String, relayURL: String, uploadResult: RelayUploadResult, contentType: RelayContentType, keepPolicy: RelayKeepPolicy, mime: String, plaintext: Data) {
        let message = EnqueueMessage.message(
            text: wire, attributes: [OutgoingContentInfoMessageAttribute(flags: .disableLinkPreviews)],
            inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil,
            localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
        let _ = (enqueueMessages(account: context.account, peerId: peerId, messages: [message])
        |> deliverOnMainQueue).startStandalone(next: { messageIds in
            guard let messageId = messageIds.first.flatMap({ $0 }) else { return }
            let accountState = SecutgRelayRuntime.shared.accountState(context: context)
            let chatKey = SecutgRelayRuntime.chatKey(peerId)
            accountState.recordSentItem(RelaySentItem(
                id: uploadResult.id, chatId: chatKey, messageId: Int64(messageId.id), relayURL: relayURL,
                deleteToken: uploadResult.deleteToken, contentType: contentType, keepPolicy: keepPolicy,
                createdAtMs: Int64(Date().timeIntervalSince1970 * 1000)))
            let text = contentType == .text ? String(decoding: plaintext, as: UTF8.self) : nil
            let imageData = contentType == .image ? plaintext : nil
            accountState.saveLocalCopy(RelayLocalCopy(
                chatId: chatKey, messageId: Int64(messageId.id), contentType: contentType, mime: mime,
                text: text, imageData: imageData, savedAtMs: Int64(Date().timeIntervalSince1970 * 1000), direction: .sent))
        })
    }
}
