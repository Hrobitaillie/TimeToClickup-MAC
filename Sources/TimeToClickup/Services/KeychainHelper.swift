import Foundation

/// Local token store. We deliberately avoid the macOS Keychain because
/// it pops a system authorization dialog on every read for unsigned
/// apps — that dialog steals focus from our search popover and makes
/// the search look like it's "going to macOS instead of ClickUp".
///
/// Tokens live in `~/Library/Preferences/<bundle>.plist`, readable
/// only by the current user. Same trust level as a `.env` file.
final class KeychainHelper {
    static let shared = KeychainHelper()

    private let prefix = "tt_"

    func set(key: String, value: String) {
        UserDefaults.standard.set(value, forKey: prefix + key)
    }

    func get(key: String) -> String? {
        UserDefaults.standard.string(forKey: prefix + key)
    }

    func clear(key: String) {
        UserDefaults.standard.removeObject(forKey: prefix + key)
    }
}
