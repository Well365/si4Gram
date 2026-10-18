import Foundation

/// PLAN.md 3.40.1: where this install's credentials come from, read from the same three places
/// `SecutgConfigFiles.load` reads — environment, `Application Support/secutg.json`, the bundled `secutg.json`.
public struct ApiCredentialStatus: Equatable {
    public let source: ApiCredentialRules.Source
    /// The pair this source supplies; nil for `.none`. The screens show its `apiId`, never its hash.
    public let inUse: ApiCredentialRules.Credentials?
    public let hasEnv: Bool
    /// The user's own pair (`user_credentials`).
    public let user: ApiCredentialRules.Credentials?
    /// The one before it, for 「恢复上一份」.
    public let previous: ApiCredentialRules.Credentials?
    /// The packager's pair: the bundled file's, else the top level of the user-override file (macOS dev builds).
    public let bundled: ApiCredentialRules.Credentials?

    public init(source: ApiCredentialRules.Source, inUse: ApiCredentialRules.Credentials?, hasEnv: Bool,
                user: ApiCredentialRules.Credentials?, previous: ApiCredentialRules.Credentials?,
                bundled: ApiCredentialRules.Credentials?) {
        self.source = source
        self.inUse = inUse
        self.hasEnv = hasEnv
        self.user = user
        self.previous = previous
        self.bundled = bundled
    }

    public var hasUser: Bool { return user != nil }
    public var hasBundled: Bool { return bundled != nil }

    /// The same status when nothing else supplies a pair and the connection falls back to the pair compiled into the
    /// app (iOS `BuildConfig`, macOS `ApiEnvironment`'s constants): that is what is in use, and it is shared like any
    /// bundled pair, so the screens and check 8 say `bundled`. It is NOT offered as option ③ or as 「恢复上一份」's
    /// fallback (`bundled` stays nil): PLAN.md 3.40.2 offers ③ only when the package's secutg.json carries a pair,
    /// as Web and Android do — a distribution build ships without one and must not lead people onto this pair.
    public func withCompiledFallback(_ compiled: ApiCredentialRules.Credentials?) -> ApiCredentialStatus {
        guard source == .none, let compiled = compiled else { return self }
        return ApiCredentialStatus(source: .bundled, inUse: compiled, hasEnv: hasEnv,
                                   user: user, previous: previous, bundled: nil)
    }

    /// What is really in use when `SecutgConfigFiles.load` threw and the app connected with the compiled pair (or
    /// with nothing): the files' answer must not claim the user's pair is in use when it never reached the
    /// connection. The user's own and previous pairs are kept so the settings page can still change or restore them.
    public func afterLoadFailure(compiled: ApiCredentialRules.Credentials?) -> ApiCredentialStatus {
        return ApiCredentialStatus(source: compiled == nil ? .none : .bundled, inUse: compiled, hasEnv: false,
                                   user: user, previous: previous, bundled: nil)
    }

    /// 3.40.3: whether 「恢复上一份」 can fall back to the bundled pair — it exists and is not the pair just rejected.
    public func hasBundledAlternative(rejected: ApiCredentialRules.Credentials?) -> Bool {
        guard let bundled = bundled else { return false }
        return bundled != rejected
    }
}

public enum ApiCredentialFiles {
    public static let envApiId = "TG_TELEGRAM_API_ID"
    public static let envApiHash = "TG_TELEGRAM_API_HASH"

    /// The environment's pair as a layer; each field is nil when unset or empty.
    public static func envLayer(_ environment: [String: String]) -> ApiCredentialRules.Layer {
        let id = environment[envApiId].flatMap { $0.isEmpty ? nil : Int32($0.trimmingCharacters(in: .whitespaces)) }
        let hash = environment[envApiHash].flatMap { $0.isEmpty ? nil : $0 }
        return ApiCredentialRules.Layer(apiId: id, apiHash: hash)
    }

    public static func status(environment: [String: String], userFileJSON: Data?, builtInJSON: Data?) -> ApiCredentialStatus {
        let env = envLayer(environment)
        let records = UserCredentialsFile.records(fromFile: userFileJSON)
        let bundled = UserCredentialsFile.topLevelLayer(builtInJSON)?.complete ?? UserCredentialsFile.topLevelLayer(userFileJSON)?.complete
        let bundledLayer = bundled.map { ApiCredentialRules.Layer(apiId: $0.apiId, apiHash: $0.apiHash) }
        let source = ApiCredentialRules.resolveSource(env: env, user: records.current, bundled: bundledLayer)
        let inUse: ApiCredentialRules.Credentials?
        switch source {
        case .env: inUse = env.complete
        case .user: inUse = records.current
        case .bundled: inUse = bundled
        case .none: inUse = nil
        }
        return ApiCredentialStatus(source: source, inUse: inUse, hasEnv: env.complete != nil,
                                   user: records.current, previous: records.previous, bundled: bundled)
    }

    /// The loader's override map with the user's pair lifted above the files (3.40.1: env > user > bundled). A whole
    /// env pair is left alone; otherwise the user's pair replaces whatever half the environment gave.
    public static func overrides(_ base: [String: String], userFileJSON: Data?) -> [String: String] {
        guard let user = UserCredentialsFile.records(fromFile: userFileJSON).current else { return base }
        let hasEnvPair = !(base[SecutgConfigLoader.keyApiId] ?? "").isEmpty && !(base[SecutgConfigLoader.keyApiHash] ?? "").isEmpty
        if hasEnvPair { return base }
        var out = base
        out[SecutgConfigLoader.keyApiId] = String(user.apiId)
        out[SecutgConfigLoader.keyApiHash] = user.apiHash
        return out
    }

    /// `status` read from the standard places, the way `SecutgConfigFiles.load` reads them.
    public static func status(bundle: Bundle = .main, userFileURL: URL? = SecutgConfigFiles.defaultUserFileURL(),
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> ApiCredentialStatus {
        let builtIn = bundle.url(forResource: "secutg", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        let user = userFileURL.flatMap { try? Data(contentsOf: $0) }
        return status(environment: environment, userFileJSON: user, builtInJSON: builtIn)
    }
}

/// What this run of the app knows about its credentials, shared by the gate, the login screen, the settings page
/// and the check-up (3.46 check 8). Set once at start-up by the app, before the network stack is built.
public final class ApiCredentialSession {
    public static let shared = ApiCredentialSession()

    private let lock = NSLock()
    private var currentStatus: ApiCredentialStatus?
    private var currentChoseBundled = false
    private var currentReminderAnswered = false

    public init() { }

    public var status: ApiCredentialStatus? {
        get { lock.lock(); defer { lock.unlock() }; return currentStatus }
        set { lock.lock(); currentStatus = newValue; lock.unlock() }
    }

    /// 3.40.2 option ③ in this run only (2026-10-02 amendment): the next start asks again.
    public var choseBundled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return currentChoseBundled }
        set { lock.lock(); currentChoseBundled = newValue; lock.unlock() }
    }

    /// 3.40.2 amendment: the launch reminder was answered in this run (〔稍后〕, or it led to the set-up page).
    public var reminderAnswered: Bool {
        get { lock.lock(); defer { lock.unlock() }; return currentReminderAnswered }
        set { lock.lock(); currentReminderAnswered = newValue; lock.unlock() }
    }

    /// 3.40.2 amendment: whether the launch reminder pops up now for a logged-in account. Asking answers it: the caller
    /// shows it at most once per run, whatever the user then does.
    public func takeLaunchReminder(isLoggedIn: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let due = ApiCredentialRules.shouldRemind(ApiCredentialRules.ReminderInput(
            source: currentStatus?.source ?? .none, isLoggedIn: isLoggedIn,
            laterThisRun: currentReminderAnswered, choseBundled: currentChoseBundled))
        if due { currentReminderAnswered = true }
        return due
    }

    /// UserDefaults key carrying option ③ over exactly one restart (see `markChoseBundledForNextLaunch`).
    public static let choseBundledNextLaunchKey = "secutg.api.choseBundledNextLaunch"

    /// 3.40.3: ③ / 「恢复上一份」 landed on the package's pair, but only a restart can apply it (the user's pair stepped
    /// aside). Without this the next start has no user pair and no ③ choice, and shows the gate again instead of
    /// the login screen (Android keeps `chose_bundled` in its prefs, Web in sessionStorage across the reload).
    public static func markChoseBundledForNextLaunch(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: choseBundledNextLaunchKey)
    }

    /// At start-up, before the gate decides: takes the carried-over choice into this run (and clears it).
    public func consumeChoseBundledFromLastRun(_ defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: ApiCredentialSession.choseBundledNextLaunchKey) else { return }
        defaults.removeObject(forKey: ApiCredentialSession.choseBundledNextLaunchKey)
        choseBundled = true
    }

    /// 3.46 check 8's input; `.none` before start-up recorded anything.
    public var source: ApiCredentialRules.Source {
        return status?.source ?? .none
    }
}
