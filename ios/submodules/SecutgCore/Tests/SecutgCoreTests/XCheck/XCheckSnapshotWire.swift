import Foundation

/// The two spellings of `masters` in a snapshot, and the translation between them.
///
/// On the wire — inside a real `K1:` container, which is what the `bundle` field of every k1 vector
/// carries — `masters` is an **array** of `{masterId, masterKey, createdAt}` records. That is what Web's
/// `KeyRingSnapshot`, Android's `TransferSnapshotJson`, this client's `TransferSnapshotCodec` and
/// Windows's `bundle.cpp` all write and read.
///
/// In a vector's `snapshot` field it is an **object keyed by masterId**, because that field is there to
/// be compared, not to be transmitted: an array carries an order, five clients iterate their maps in
/// five orders, and an order-sensitive comparison of an unordered thing produces failures that mean
/// nothing. Keying by the record's own identity removes the question.
///
/// Keeping both straight matters: `forVector` on the way out, `forDecoder` on the way in. Feeding the
/// keyed form to a decoder that expects an array is not an error anywhere — it is a snapshot that
/// silently arrives with no keys in it, which is the single most expensive way this harness could lie.
enum XCheckSnapshotWire {
    /// Wire form to vector form: the `masters` array becomes an object keyed by `masterId`.
    static func forVector(_ wire: [String: Any]) -> [String: Any] {
        guard let masters = wire["masters"] as? [[String: Any]] else { return wire }
        var keyed = [String: Any]()
        for (index, record) in masters.enumerated() {
            var copy = record
            let masterId = (copy.removeValue(forKey: "masterId") as? String) ?? "?\(index)"
            keyed[masterId] = copy
        }
        var out = wire
        out["masters"] = keyed
        return out
    }

    /// Vector form back to wire form, so it can be fed to this client's own decoder.
    static func forDecoder(_ vector: [String: Any]) -> [String: Any] {
        guard let keyed = vector["masters"] as? [String: Any] else { return vector }
        var array = [[String: Any]]()
        for (masterId, value) in keyed {
            guard var record = value as? [String: Any] else { continue }
            record["masterId"] = masterId
            array.append(record)
        }
        var out = vector
        out["masters"] = array
        return out
    }
}
