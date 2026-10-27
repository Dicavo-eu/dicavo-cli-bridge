import Foundation
import os

/// The language every text Dicavo builds in code speaks.
///
/// `String(localized:)` takes the language from the bundle, which follows the
/// system, not the language chosen in Dicavo's own settings; its `locale:`
/// argument only formats numbers and dates. SwiftUI's `Text` follows the
/// environment, but a string made in code, a window title AppKit draws, and
/// the CLI Bridge, which is another process, never see that environment.
/// Everything that is not a SwiftUI literal goes through `text(_:)`.
///
/// The Mac app sets `code` from its setting and shares it through the App
/// Group, so the Bridge speaks the same language. The iPhone sets nothing and
/// follows the system.
enum InterfaceLanguage {
    static let appGroup = "H8LTS9AT3K.cz.smartbrains.dicavo"
    static let sharedKey = "dicavoInterfaceLanguage"
    /// Posted, without a payload, when the Mac app's language changes.
    static let changedNotification = Notification.Name("cz.smartbrains.dicavo.interfaceLanguageChanged")

    private static let chosen = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Inside a test run nothing is shared with the real App Group and the
    /// language is English unless a test sets one, so results do not depend
    /// on the machine, its system language or the order tests run in.
    static let isTesting = NSClassFromString("XCTestCase") != nil

    /// The language this process chose, as an ISO code; nil to follow the
    /// language the Mac app shared, or else the system.
    static var code: String? {
        get { chosen.withLock { $0 } }
        set { chosen.withLock { $0 = newValue } }
    }

    /// Shares `code` with the other apps of the group and tells them.
    static func share(_ code: String) {
        guard !isTesting else { return }
        UserDefaults(suiteName: appGroup)?.set(code, forKey: sharedKey)
        #if os(macOS)
        DistributedNotificationCenter.default().postNotificationName(
            changedNotification, object: nil, userInfo: nil, deliverImmediately: true
        )
        #endif
    }

    /// The language the Mac app last shared, for a process without its own.
    static var sharedCode: String? {
        guard !isTesting else { return nil }
        return UserDefaults(suiteName: appGroup)?.string(forKey: sharedKey)
    }

    static var locale: Locale {
        if let code = code ?? sharedCode { return Locale(identifier: code) }
        if isTesting { return Locale(identifier: "en") }
        return Locale(identifier: Locale.preferredLanguages.first ?? "en")
    }

    /// `text` from the process's string catalog in the interface language.
    static func text(_ text: LocalizedStringResource) -> String {
        var text = text
        text.locale = locale
        return String(localized: text)
    }
}
