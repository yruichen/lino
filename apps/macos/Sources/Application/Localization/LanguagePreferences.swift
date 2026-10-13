import Foundation

enum InterfaceLanguage: String, CaseIterable {
    case system, english = "en", simplifiedChinese = "zh-Hans"
}

@MainActor
final class LanguagePreferences {
    static let shared = LanguagePreferences()
    private(set) var preference: InterfaceLanguage = .system
    private(set) var locale = "en"
    private var preferredLanguages: [String] = ["en"]
    private var persistsPreference = false
    private var bundle = Bundle.main

    private init() {}

    func configure(verifying: Bool) {
        persistsPreference = !verifying
        preferredLanguages = verifying ? ["en"] : Locale.preferredLanguages
        let stored = verifying ? nil : UserDefaults.standard.string(forKey: "interfaceLanguage")
        update(InterfaceLanguage(rawValue: stored ?? "") ?? .system, persist: false)
    }

    static func resolve(_ preference: InterfaceLanguage, preferredLanguages: [String]) -> String {
        guard preference == .system else { return preference.rawValue }
        for language in preferredLanguages {
            if language.lowercased().hasPrefix("zh") { return "zh-Hans" }
            if language.lowercased().hasPrefix("en") { return "en" }
        }
        return "en"
    }

    func select(_ preference: InterfaceLanguage) {
        if persistsPreference { preferredLanguages = Locale.preferredLanguages }
        update(preference, persist: persistsPreference)
    }

    private func update(_ preference: InterfaceLanguage, persist: Bool) {
        self.preference = preference
        locale = Self.resolve(preference, preferredLanguages: preferredLanguages)
        bundle = Bundle.main.path(forResource: locale, ofType: "lproj").flatMap(Bundle.init(path:)) ?? Bundle.main
        if persist { UserDefaults.standard.set(preference.rawValue, forKey: "interfaceLanguage") }
    }

    func string(_ key: String, arguments: [CVarArg]) -> String {
        let format = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        return arguments.isEmpty ? format : String(format: format, locale: Locale(identifier: locale), arguments: arguments)
    }
}

@MainActor
func localized(_ key: String, _ arguments: CVarArg...) -> String {
    LanguagePreferences.shared.string(key, arguments: arguments)
}
