import Foundation

/// The pure half of sending through a relay (PLAN.md 3.48.2 / 3.48.3): what bytes go in the upload body, and
/// what the resulting `L1:` reference looks like once the relay has answered. All I/O (the actual upload, the
/// enqueue onto the chat) stays in the app layer; this stays testable without either.
public enum RelaySend {
    public struct PreparedUpload: Equatable {
        public let body: Data
        /// What the relay is told in `X-Relay-Mime` — `application/octet-stream` when encrypted, so the relay
        /// never learns the real content type (PLAN.md 3.48.2).
        public let uploadMime: String
        public let contentKey: [UInt8]?
    }

    public static func prepareUpload(plaintext: Data, originalMime: String, encrypt: Bool) throws -> PreparedUpload {
        guard encrypt else {
            return PreparedUpload(body: plaintext, uploadMime: originalMime, contentKey: nil)
        }
        let key = RelayCrypto.generateKey()
        let sealed = try RelayCrypto.seal(plaintext, key: key)
        return PreparedUpload(body: sealed, uploadMime: "application/octet-stream", contentKey: key)
    }

    /// Builds the `L1:` reference from the relay's own answer to `POST /v1/items` — `id`, `expires_at` and
    /// `max_reads` are the relay's, never chosen locally.
    public static func buildReference(relayURL: String, uploadResult: RelayUploadResult, contentType: RelayContentType, originalMime: String, sizeBytes: Int, contentKey: [UInt8]?) -> RelayL1Reference {
        return RelayL1Reference(
            relayURL: relayURL,
            id: uploadResult.id,
            contentType: contentType,
            mime: originalMime,
            sizeBytes: sizeBytes,
            maxReads: uploadResult.maxReads,
            expiresAt: uploadResult.expiresAt,
            contentKey: contentKey.map { Base64Url.encode($0) })
    }

    /// Whether this content is too big for the relay to accept — checked locally before uploading, using the
    /// relay's own `/v1/info` limits when known, else PLAN.md 3.48.1's absolute ceiling.
    public static func exceedsLimit(sizeBytes: Int, contentType: RelayContentType, info: RelayInfo?) -> Bool {
        guard let info = info else { return sizeBytes > RelayL1.maxBytes }
        let limit = contentType == .text ? info.maxTextBytes : info.maxImageBytes
        return sizeBytes > limit
    }
}

/// The pure half of receiving (PLAN.md 3.48.2 / 3.48.4): turning a fetched blob back into content, given the
/// reference that described it.
public enum RelayReceive {
    /// nil `ref.contentKey` means the upload was never encrypted — the fetched body IS the content. Otherwise
    /// opens the sealed blob; nil on any failure (wrong key, truncated, tampered).
    public static func open(ref: RelayL1Reference, fetchedBody: Data) -> Data? {
        guard let keyB64 = ref.contentKey else { return fetchedBody }
        guard let key = Base64Url.decode(keyB64), key.count == RelayCrypto.keyBytes else { return nil }
        return RelayCrypto.open(fetchedBody, key: key)
    }
}
