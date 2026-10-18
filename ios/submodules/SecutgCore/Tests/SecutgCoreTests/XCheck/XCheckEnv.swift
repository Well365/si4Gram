import Clibsodium
import Foundation
@testable import SecutgCore

/// Environment and shared inputs of the cross-client vector run (see `xcheck/README.md`).
///
/// Two environment variables gate everything. `SECUTG_VECTOR_OUT` turns the producer test on and names
/// the directory the vectors are written under; `SECUTG_VECTOR_IN` turns the consumer test on and names
/// the directory the other clients' vectors are read from. With neither set — which is how
/// `swift test --package-path …/SecutgCore` runs on its own — both tests skip and this package behaves
/// exactly as it did before.
///
/// `inputs.json` is deliberately **not** copied into this repository. Every client reads the same file
/// from the runner's directory, so the five of them cannot drift apart on their own inputs, and the
/// sha256 prefix of that file travels in every vector as `inputsId`: a consumer that reads a vector
/// generated against different inputs refuses it instead of quietly passing.
struct XCheckEnv {
    /// This client's name; also the subdirectory its vectors are written to.
    ///
    /// iOS and macOS compile these very files from two separate checkouts, and the whole point of
    /// keeping both in the matrix is that those checkouts drift. So the name cannot be written into the
    /// source — that would make the two files differ and hide exactly what they are here to reveal. It
    /// comes from the runner, and falls back to the compile-time path of this file, which is the one
    /// thing that genuinely differs between the two trees.
    static let client: String = {
        if let explicit = env("SECUTG_VECTOR_CLIENT") { return explicit }
        return #filePath.contains("secuTG-macos") ? "macos" : "ios"
    }()
    static let format = 1

    let root: URL
    let inputsFile: URL
    let inputs: [String: Any]
    let inputsId: String

    /// nil when the variable is unset or blank.
    static func env(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func outRoot() -> URL? {
        return env("SECUTG_VECTOR_OUT").map { URL(fileURLWithPath: $0) }
    }

    static func inRoot() -> URL? {
        return env("SECUTG_VECTOR_IN").map { URL(fileURLWithPath: $0) }
    }

    /// The runner's `--suite`, as a comma-separated list, or nil when the whole matrix is being run. Honouring it
    /// is what lets someone bringing one suite up on one client run it alone instead of paying for all of them.
    static func selectedSuites() -> [String]? {
        guard let raw = env("SECUTG_VECTOR_SUITE") else { return nil }
        let names = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return names.isEmpty ? nil : names
    }

    /// Where the consumer writes its verdicts; the runner reads these files rather than parsing stdout.
    static func resultsDir(_ input: URL) -> URL {
        if let explicit = env("SECUTG_VECTOR_RESULTS") { return URL(fileURLWithPath: explicit) }
        return input.deletingLastPathComponent().appendingPathComponent("results")
    }

    static func load(_ root: URL) throws -> XCheckEnv {
        let file = try resolveInputs(root)
        let raw = try Data(contentsOf: file)
        guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw XCheckError.message("inputs.json is not a JSON object: \(file.path)")
        }
        guard (object["format"] as? NSNumber)?.intValue == format else {
            throw XCheckError.message("inputs.json format \(object["format"] ?? "nil"), expected \(format)")
        }
        guard let version = object["inputsVersion"] as? String else {
            throw XCheckError.message("inputs.json has no inputsVersion")
        }
        return XCheckEnv(root: root, inputsFile: file, inputs: object,
                         inputsId: version + ":" + XCheckDigest.sha256Prefix(raw))
    }

    private static func resolveInputs(_ root: URL) throws -> URL {
        if let explicit = env("SECUTG_VECTOR_INPUTS") { return URL(fileURLWithPath: explicit) }
        var dir = root.standardizedFileURL
        for _ in 0..<3 {
            let candidate = dir.appendingPathComponent("inputs.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        throw XCheckError.message("no inputs.json at or above \(root.path) — set SECUTG_VECTOR_INPUTS")
    }

    // MARK: shortcuts into inputs.json

    func section(_ name: String) throws -> [String: Any] {
        guard let value = inputs[name] as? [String: Any] else {
            throw XCheckError.message("inputs.json has no object named \(name)")
        }
        return value
    }

    func list(_ name: String) throws -> [[String: Any]] {
        guard let value = inputs[name] as? [[String: Any]] else {
            throw XCheckError.message("inputs.json has no array named \(name)")
        }
        return value
    }

    func master(_ name: String) throws -> [String: Any] {
        for record in try list("masters") where record["name"] as? String == name { return record }
        throw XCheckError.message("no master named \(name) in inputs.json")
    }

    func masterKey(_ name: String) throws -> [UInt8] {
        guard let text = try master(name)["keyHex"] as? String, let bytes = Hex.decode(text) else {
            throw XCheckError.message("master \(name) has no usable keyHex")
        }
        return bytes
    }

    func identity(_ name: String) throws -> [String: Any] {
        guard let value = try section("identities")[name] as? [String: Any] else {
            throw XCheckError.message("no identity named \(name) in inputs.json")
        }
        return value
    }

    func bytes(_ object: [String: Any], _ key: String) throws -> [UInt8] {
        guard let text = object[key] as? String, let value = Hex.decode(text) else {
            throw XCheckError.message("no hex string at \(key)")
        }
        return value
    }

    func label(_ which: String) throws -> String {
        guard let value = try section("labels")[which] as? String else {
            throw XCheckError.message("no label named \(which)")
        }
        return value
    }

    func nowMs() throws -> Int64 {
        return (try section("now")["ms"] as? NSNumber)?.int64Value ?? 0
    }

    func nowSeconds() throws -> Int64 {
        return (try section("now")["seconds"] as? NSNumber)?.int64Value ?? 0
    }

    func epochDays() throws -> Int {
        return (try section("epoch")["days"] as? NSNumber)?.intValue ?? 1
    }

    func epochTolerance() throws -> Int {
        return (try section("epoch")["tolerance"] as? NSNumber)?.intValue ?? 1
    }

    // MARK: vector files

    func envelope(suite: String, cases: [[String: Any]]) -> [String: Any] {
        return [
            "$comment": inputs["$comment"] ?? "",
            "format": XCheckEnv.format,
            "suite": suite,
            "producer": ["client": XCheckEnv.client, "generatedAt": Int(Date().timeIntervalSince1970)],
            "inputsId": inputsId,
            "cases": cases,
        ]
    }

    func write(suite: String, cases: [[String: Any]]) throws {
        let dir = root.appendingPathComponent(XCheckEnv.client)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: envelope(suite: suite, cases: cases),
                                              options: [.sortedKeys, .prettyPrinted])
        try data.write(to: dir.appendingPathComponent(suite + ".json"))
    }

    static func read(_ file: URL) throws -> [String: Any] {
        let raw = try Data(contentsOf: file)
        guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw XCheckError.message("not a JSON object: \(file.path)")
        }
        return object
    }
}

enum XCheckError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        if case let .message(text) = self { return text }
        return "xcheck error"
    }
}

/// A sha256 prefix without pulling CryptoKit in: libsodium is already linked and already the thing
/// every other digest in this package goes through.
enum XCheckDigest {
    static func sha256Prefix(_ data: Data) -> String {
        var out = [UInt8](repeating: 0, count: 32)
        let bytes = [UInt8](data)
        _ = SecutgSodium.ensureReady()
        _ = crypto_hash_sha256(&out, bytes, UInt64(bytes.count))
        return Hex.encode(out[0..<8])
    }
}
