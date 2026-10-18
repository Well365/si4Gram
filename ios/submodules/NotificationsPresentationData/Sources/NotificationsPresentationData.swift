import Foundation

public struct NotificationsPresentationData: Codable, Equatable {
    public var applicationLockedMessageString: String
    public var incomingCallString: String
    /// SECUTG-HOOK (feature, 2026-09-29, PLAN.md 3.42): the in-app language (`SecutgL10n.Lang` raw value), so the
    /// notification extension's placeholders follow it. Optional: a file written before this field decodes without it.
    public var languageCode: String?
    
    public init(applicationLockedMessageString: String, incomingCallString: String, languageCode: String? = nil) {
        self.applicationLockedMessageString = applicationLockedMessageString
        self.incomingCallString = incomingCallString
        self.languageCode = languageCode
    }
}

public func notificationsPresentationDataPath(rootPath: String) -> String {
    return rootPath + "/notificationsPresentationData.json"
}
