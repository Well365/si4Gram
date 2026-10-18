import Foundation

/// PLAN.md 3.38 item 3: the password has a minimum length, counted in Unicode code points after NFC
/// (Swift `unicodeScalars`, not UTF-16 units, not bytes, not grapheme clusters).
public enum PasswordCheck: String, Equatable {
    case ok
    case tooShort = "too_short"
    case tooLong = "too_long"
}

extension GroupPassword {
    public static let passwordMinCodePoints = 6
    public static let passwordMaxCodePoints = 256

    public static func countCodePoints(_ text: String) -> Int {
        return text.precomposedStringWithCanonicalMapping.unicodeScalars.count
    }

    public static func validatePassword(_ password: String) -> PasswordCheck {
        let n = countCodePoints(password)
        if n < passwordMinCodePoints { return .tooShort }
        if n > passwordMaxCodePoints { return .tooLong }
        return .ok
    }
}
