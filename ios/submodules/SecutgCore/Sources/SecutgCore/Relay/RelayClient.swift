import Foundation

/// The relay HTTP surface (PLAN.md 3.48.3): `GET /v1/info`, `POST /v1/items`, `GET /v1/items/{id}/meta`,
/// `GET /v1/items/{id}`, `DELETE /v1/items/{id}`.
public struct RelayInfo: Equatable {
    public let service: String
    public let version: Int
    public let maxTextBytes: Int
    public let maxImageBytes: Int
    public let maxTtlSeconds: Int
    public let maxReads: Int
    public let uploadTokenRequired: Bool
}

public struct RelayUploadResult: Equatable {
    public let id: String
    public let expiresAt: Int64
    public let maxReads: Int
    public let deleteToken: String
}

public struct RelayMeta: Equatable {
    public let type: String
    public let mime: String
    public let size: Int
    /// nil = unlimited.
    public let readsLeft: Int?
    public let expiresAt: Int64
}

public enum RelayClientError: Error, Equatable {
    case invalidURL
    case transport(String)
    case decode
    /// HTTP status plus the service's own `{error:{code,message}}` body, when it parsed.
    case http(status: Int, code: String?, message: String?)
}

/// Minimal transport seam: production uses `URLSession` (via `RelayURLSessionTransport`); tests inject a
/// closure and never touch the network, which is also what keeps "relay off → no network" true at the
/// unit-test level, not just by code inspection.
///
/// The `Int` parameter is `maxBytes` (PLAN.md review HIGH-2): the hard cap on the response body this request
/// may ever be handed back as. A conforming transport MUST stop accepting bytes — cancelling the underlying
/// transfer rather than buffering further — the moment it would be exceeded, and MUST reject up front when a
/// claimed `Content-Length` already exceeds it; it must never rely on the caller to discard an oversized
/// `Data` after the fact. The injected test transport is free to ignore it (nothing in a test actually streams
/// unbounded bytes), but the production transport must not.
public typealias RelayTransport = (URLRequest, Int, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void

/// The error a capped transport reports when a response is rejected for exceeding its byte cap — before or
/// during download, never after buffering the whole thing into memory first.
public struct RelayResponseTooLarge: Error, Equatable {
    public init() {}
}

/// Production transport: enforces `maxBytes` as a true streaming cap via a per-request `URLSessionDataDelegate`
/// — it rejects a response whose `Content-Length` already exceeds the cap before a single body byte is read,
/// and cancels the transfer the instant accumulated bytes exceed it, so a malicious or buggy relay can never
/// make this process buffer more than `maxBytes` bytes for any one request (PLAN.md review HIGH-2).
public enum RelayURLSessionTransport {
    public static let shared: RelayTransport = { request, maxBytes, completion in
        let delegate = RelayCappedSessionDelegate(maxBytes: maxBytes, completion: completion)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        session.dataTask(with: request).resume()
    }
}

/// Backs `RelayURLSessionTransport`. One instance per request (a fresh ephemeral `URLSession` is created per
/// call), so there is no shared mutable state across requests to reason about.
private final class RelayCappedSessionDelegate: NSObject, URLSessionDataDelegate {
    private let maxBytes: Int
    private let completion: (Data?, URLResponse?, Error?) -> Void
    private var buffer = Data()
    private var capturedResponse: URLResponse?
    private var finished = false

    init(maxBytes: Int, completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        self.maxBytes = maxBytes
        self.completion = completion
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        capturedResponse = response
        guard RelayCap.isAcceptableClaimedLength(response.expectedContentLength, cap: maxBytes) else {
            finish(data: nil, response: response, error: RelayResponseTooLarge())
            completionHandler(.cancel)
            session.finishTasksAndInvalidate()
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        buffer.append(data)
        if RelayCap.exceedsCapSoFar(receivedBytes: buffer.count, cap: maxBytes) {
            finish(data: nil, response: capturedResponse, error: RelayResponseTooLarge())
            dataTask.cancel()
            session.finishTasksAndInvalidate()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        finish(data: buffer, response: capturedResponse, error: error)
    }

    private func finish(data: Data?, response: URLResponse?, error: Error?) {
        guard !finished else { return }
        finished = true
        completion(data, response, error)
    }
}

public final class RelayClient {
    private let transport: RelayTransport

    public init(transport: @escaping RelayTransport = RelayURLSessionTransport.shared) {
        self.transport = transport
    }

    public func info(baseURL: String, completion: @escaping (Result<RelayInfo, RelayClientError>) -> Void) {
        guard let url = URL(string: baseURL + "/v1/info") else { return completion(.failure(.invalidURL)) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.defaultTimeout
        send(request, maxBytes: RelayCap.metadataCapBytes) { result in
            completion(result.flatMap { data in
                guard let object = Self.jsonObject(data),
                      let service = object["service"] as? String,
                      let version = Self.intValue(object["version"]),
                      let maxTextBytes = Self.intValue(object["max_text_bytes"]),
                      let maxImageBytes = Self.intValue(object["max_image_bytes"]),
                      let maxTtlSeconds = Self.intValue(object["max_ttl_seconds"]),
                      let maxReads = Self.intValue(object["max_reads"]) else {
                    return .failure(.decode)
                }
                let tokenRequired = (object["upload_token_required"] as? NSNumber)?.boolValue ?? false
                return .success(RelayInfo(service: service, version: version, maxTextBytes: maxTextBytes, maxImageBytes: maxImageBytes, maxTtlSeconds: maxTtlSeconds, maxReads: maxReads, uploadTokenRequired: tokenRequired))
            })
        }
    }

    public func upload(baseURL: String, token: String?, contentType: RelayContentType, mime: String, maxReads: Int, ttlSeconds: Int, body: Data, completion: @escaping (Result<RelayUploadResult, RelayClientError>) -> Void) {
        guard let url = URL(string: baseURL + "/v1/items") else { return completion(.failure(.invalidURL)) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = Self.transferTimeout
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(contentType == .text ? "text" : "image", forHTTPHeaderField: "X-Relay-Type")
        request.setValue(mime, forHTTPHeaderField: "X-Relay-Mime")
        request.setValue(String(maxReads), forHTTPHeaderField: "X-Relay-Max-Reads")
        request.setValue(String(ttlSeconds), forHTTPHeaderField: "X-Relay-TTL")
        if let token = token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // The upload response is a small fixed-shape JSON ack (id/expires_at/max_reads/delete_token), never the
        // uploaded content itself — same metadata cap as `/v1/info` and `/meta` (PLAN.md review HIGH-2).
        send(request, maxBytes: RelayCap.metadataCapBytes) { result in
            completion(result.flatMap { data in
                guard let object = Self.jsonObject(data),
                      let id = object["id"] as? String,
                      let expiresAt = Self.int64Value(object["expires_at"]),
                      let maxReads = Self.intValue(object["max_reads"]),
                      let deleteToken = object["delete_token"] as? String else {
                    return .failure(.decode)
                }
                return .success(RelayUploadResult(id: id, expiresAt: expiresAt, maxReads: maxReads, deleteToken: deleteToken))
            })
        }
    }

    public func meta(baseURL: String, id: String, completion: @escaping (Result<RelayMeta, RelayClientError>) -> Void) {
        guard let url = URL(string: baseURL + "/v1/items/\(id)/meta") else { return completion(.failure(.invalidURL)) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.defaultTimeout
        send(request, maxBytes: RelayCap.metadataCapBytes) { result in
            completion(result.flatMap { data in
                guard let object = Self.jsonObject(data),
                      let type = object["type"] as? String,
                      let mime = object["mime"] as? String,
                      let size = Self.intValue(object["size"]),
                      let expiresAt = Self.int64Value(object["expires_at"]) else {
                    return .failure(.decode)
                }
                let readsLeft = (object["reads_left"] is NSNull) ? nil : Self.intValue(object["reads_left"])
                return .success(RelayMeta(type: type, mime: mime, size: size, readsLeft: readsLeft, expiresAt: expiresAt))
            })
        }
    }

    /// `expectedPlaintextBytes`/`isEncrypted` come from the already-parsed `L1:` reference's own `n`/`k`
    /// (PLAN.md 3.48.1) — this is what lets the cap be exact rather than just "under 20 MiB" (PLAN.md review
    /// HIGH-2): the response must be exactly `RelayCap.expectedItemBytes(plaintextSize:isEncrypted:)` bytes, no
    /// more (enforced by the transport, streaming) and no less (checked here once the transfer completes).
    public func get(baseURL: String, id: String, expectedPlaintextBytes: Int, isEncrypted: Bool, completion: @escaping (Result<Data, RelayClientError>) -> Void) {
        guard let url = URL(string: baseURL + "/v1/items/\(id)") else { return completion(.failure(.invalidURL)) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.transferTimeout
        let expectedBytes = RelayCap.expectedItemBytes(plaintextSize: expectedPlaintextBytes, isEncrypted: isEncrypted)
        let cap = RelayCap.itemCap(plaintextSize: expectedPlaintextBytes, isEncrypted: isEncrypted)
        send(request, maxBytes: cap) { result in
            switch result {
            case .success(let data):
                // PLAN.md review HIGH-2 "reject a final content length != n": a short read would otherwise be
                // silently accepted for unencrypted content (an encrypted one would already fail to open, but
                // this check catches both the same way, before decryption is even attempted). Mapped to
                // `.decode` so the app layer shows it exactly like a decrypt failure — it reuses that existing
                // string rather than inventing a new one.
                guard RelayCap.isExactLength(data.count, expectedBytes: expectedBytes) else {
                    completion(.failure(.decode))
                    return
                }
                completion(.success(data))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// A delete that 404s (already gone) is not a failure from the sender's point of view — the end state they
    /// wanted (nobody can fetch this content) already holds. Matches the Web oracle's `deleteRelayItem` exactly;
    /// without this, revoking an item that already expired or was already read to completion would be reported
    /// as a failed withdraw and queued for a retry that could never succeed.
    public func delete(baseURL: String, id: String, deleteToken: String, completion: @escaping (Result<Void, RelayClientError>) -> Void) {
        guard let url = URL(string: baseURL + "/v1/items/\(id)") else { return completion(.failure(.invalidURL)) }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = Self.defaultTimeout
        request.setValue(deleteToken, forHTTPHeaderField: "X-Delete-Token")
        send(request, treatNotFoundAsSuccess: true, maxBytes: RelayCap.metadataCapBytes) { result in completion(result.map { _ in () }) }
    }

    // MARK: - Shared plumbing

    /// PLAN.md 3.48.3: 8s for info/meta/delete, 30s for a transfer that may carry up to 20 MiB — same split the
    /// Web oracle uses (`DEFAULT_TIMEOUT_MS` / `TRANSFER_TIMEOUT_MS`).
    static let defaultTimeout: TimeInterval = 8
    static let transferTimeout: TimeInterval = 30

    private func send(_ request: URLRequest, treatNotFoundAsSuccess: Bool = false, maxBytes: Int, completion: @escaping (Result<Data, RelayClientError>) -> Void) {
        transport(request, maxBytes) { data, response, error in
            if let error = error {
                return completion(.failure(.transport(error.localizedDescription)))
            }
            guard let http = response as? HTTPURLResponse else {
                return completion(.failure(.transport("no response")))
            }
            if treatNotFoundAsSuccess && http.statusCode == 404 {
                return completion(.success(Data()))
            }
            guard (200...299).contains(http.statusCode) else {
                let (code, message) = Self.errorBody(data)
                return completion(.failure(.http(status: http.statusCode, code: code, message: message)))
            }
            completion(.success(data ?? Data()))
        }
    }

    private static func errorBody(_ data: Data?) -> (String?, String?) {
        guard let data = data, let object = jsonObject(data), let errorObject = object["error"] as? [String: Any] else {
            return (nil, nil)
        }
        return (errorObject["code"] as? String, errorObject["message"] as? String)
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func intValue(_ any: Any?) -> Int? {
        return (any as? NSNumber)?.intValue
    }

    private static func int64Value(_ any: Any?) -> Int64? {
        return (any as? NSNumber)?.int64Value
    }
}
