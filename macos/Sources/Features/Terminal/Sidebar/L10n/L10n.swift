import Foundation
import SwiftUI

/// A language MyGhost's own interface can be shown in. English is the source
/// text written in code; the others come from `L10nStrings.table`.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"
    case japanese = "ja"

    var id: String { rawValue }

    /// The language's name written in that language, so it can be found
    /// whatever the interface is showing right now.
    var nativeName: String {
        switch self {
        case .english: return "English"
        case .traditionalChinese: return "繁體中文"
        case .simplifiedChinese: return "简体中文"
        case .japanese: return "日本語"
        }
    }

    /// The supported language closest to the system's preferred languages.
    static var system: AppLanguage {
        for code in Locale.preferredLanguages {
            let lower = code.lowercased()
            if lower.hasPrefix("ja") { return .japanese }
            if lower.hasPrefix("zh") {
                // zh-Hant, zh-TW, zh-HK, zh-MO are Traditional; the rest Simplified.
                if lower.contains("hant") || lower.contains("-tw")
                    || lower.contains("-hk") || lower.contains("-mo") {
                    return .traditionalChinese
                }
                return .simplifiedChinese
            }
            if lower.hasPrefix("en") { return .english }
        }
        return .english
    }
}

/// Which language the interface is in. Chosen from the globe menu at the top
/// right; nil follows the system. Views that show text observe this, so a
/// switch takes effect at once, without a restart.
@MainActor
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    /// The user's pick. nil follows the system language.
    @Published var choice: AppLanguage? {
        didSet {
            UserDefaults.standard.set(choice?.rawValue, forKey: Self.defaultsKey)
            Self.current = language
        }
    }

    /// The language actually shown.
    var language: AppLanguage { choice ?? .system }

    /// Readable from any thread, for `L` — alerts and status text are built
    /// outside of views too.
    nonisolated(unsafe) fileprivate static var current: AppLanguage = .english

    private static let defaultsKey = "MyGhostInterfaceLanguage"

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey)
        choice = saved.flatMap(AppLanguage.init(rawValue:))
        Self.current = language
    }
}

/// The interface text for `english` in the current language. Text with no
/// translation yet is shown in English rather than not at all.
func L(_ english: String) -> String {
    let language = LanguageManager.current
    guard language != .english else { return english }
    return L10nStrings.table[english]?[language] ?? english
}

/// `L` for text with values in it: `english` is a format string (`%@`, `%d`),
/// and each translation keeps the same placeholders in the same order.
func L(_ english: String, _ args: CVarArg...) -> String {
    String(format: L(english), arguments: args)
}
