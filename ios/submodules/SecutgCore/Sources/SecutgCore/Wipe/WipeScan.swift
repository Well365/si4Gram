import Foundation

/// The pure decision behind the Saved Messages wipe scan (PLAN.md 3.22.3 / 3.22.5).
///
/// Every input is a fact the caller already holds, so the whole decision is testable without any
/// Telegram or storage dependency. The iOS runtime and the macOS runtime both build the candidate
/// list from their own message store and hand it here; the logic that picks the trigger lives once.
public enum WipeScan {
    /// One Saved Messages entry, reduced to what the decision needs. `date` is unix seconds.
    public struct Candidate: Equatable {
        public let id: Int64
        public let text: String
        public let date: Int64

        public init(id: Int64, text: String, date: Int64) {
            self.id = id
            self.text = text
            self.date = date
        }
    }

    /// What this device already acted on (PLAN.md 3.22.5). Survives the wipe on purpose — it is the
    /// only thing standing between the user and an account that wipes itself a minute after every
    /// login for thirty days, because the phrase stays in Saved Messages that whole time.
    ///
    /// Holds a user id, a message id and a timestamp — no content, no key material. This is the one
    /// exception to 3.16's "leave nothing behind", so it must NOT live in the keyring (the wipe
    /// destroys that); the runtime persists it separately (iOS: UserDefaults; Web: localStorage).
    public struct Consumed: Equatable {
        public let userId: String
        public let messageId: Int64
        /// The `date` of the trigger message itself, in unix SECONDS — the watermark every later scan
        /// compares against. `executedAt` below is this device's own clock in MILLISECONDS at the moment
        /// it wiped. Two different quantities in two different units; never substitute one for the other.
        ///
        /// 0 means "written before this field existed": the lowest possible watermark, which re-arms
        /// every in-window phrase exactly once. See `isAfterConsumed`.
        public let triggerDate: Int64
        public let executedAt: Int64

        public init(userId: String, messageId: Int64, triggerDate: Int64, executedAt: Int64) {
            self.userId = userId
            self.messageId = messageId
            self.triggerDate = triggerDate
            self.executedAt = executedAt
        }
    }

    public struct Options {
        public let nowSeconds: Int64
        public let userId: String
        public let customPhrase: String?
        public let consumed: Consumed?

        public init(nowSeconds: Int64, userId: String, customPhrase: String? = nil, consumed: Consumed? = nil) {
            self.nowSeconds = nowSeconds
            self.userId = userId
            self.customPhrase = customPhrase
            self.consumed = consumed
        }
    }

    /// Whether `entry` is strictly newer than the trigger this device already acted on — the whole of
    /// the marker's meaning (PLAN.md 3.22.5).
    ///
    /// It is a WATERMARK, not a single id to skip. "Skip exactly this one message" was an infinite wipe
    /// loop hiding in plain sight: 3.22.7 has every hand wipe post a fresh phrase to Saved Messages, so
    /// two live phrases there is the ordinary state. With #10 and #20 both in the window, a marker
    /// holding #20 let the next scan pick #10 — a different id, therefore "new" — wipe, store #10, and
    /// then find #20 "new" all over again. A wipe per login and per five-minute pass, for as long as the
    /// older phrase stayed inside the thirty-day window.
    ///
    /// The order is the one the sort below uses: by date, ties broken by id.
    private static func isAfterConsumed(_ entry: Candidate, _ consumed: Consumed?) -> Bool {
        guard let consumed = consumed else { return true }
        return entry.date > consumed.triggerDate
            || (entry.date == consumed.triggerDate && entry.id > consumed.messageId)
    }

    /// The newest Saved Messages entry that is the phrase, is inside the 30-day window, and is newer
    /// than the one this device already acted on. A *later* message carrying the phrase fires again,
    /// which is what makes the trigger reusable after a wipe; an earlier one never does (PLAN.md 3.22.5).
    public static func findTrigger(_ candidates: [Candidate], options: Options) -> Candidate? {
        let oldest = options.nowSeconds - Int64(WipePhrase.scanDays) * 24 * 60 * 60
        // A marker belongs to the account that wrote it; another account's history is not ours to skip.
        let spent: Consumed? = (options.consumed?.userId == options.userId) ? options.consumed : nil

        return candidates
            .filter { entry in
                entry.date >= oldest
                    && isAfterConsumed(entry, spent)
                    && WipePhrase.matches(entry.text, customPhrase: options.customPhrase)
            }
            .sorted { a, b in
                a.date != b.date ? a.date > b.date : a.id > b.id
            }
            .first
    }
}
