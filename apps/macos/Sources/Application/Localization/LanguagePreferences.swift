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
    private var usesSystemLanguages = true
    private var bundle = Bundle.main

    private init() {}

    func configure(verifying: Bool) {
        usesSystemLanguages = !verifying
        preferredLanguages = verifying ? ["en"] : Locale.preferredLanguages
        update(.system)
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
        if usesSystemLanguages { preferredLanguages = Locale.preferredLanguages }
        update(preference)
    }

    private func update(_ preference: InterfaceLanguage) {
        self.preference = preference
        locale = Self.resolve(preference, preferredLanguages: preferredLanguages)
        bundle = Bundle.main.path(forResource: locale, ofType: "lproj").flatMap(Bundle.init(path:)) ?? Bundle.main
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

// Keep the original code and diagnostic on BackendFailure; present the action
// the user can take rather than appending untranslated runtime messages.
@MainActor
func userFacingError(_ error: Error) -> String {
    guard let failure = error as? BackendFailure else {
        let native = error as NSError
        if native.domain == "Lino" || native.domain == "Lino.Resources" { return native.localizedDescription }
        NSLog("Lino operation failed [%@]: %@", native.domain, native.localizedDescription)
        return localized(native.domain == NSCocoaErrorDomain || native.domain == NSURLErrorDomain ? "failure.io" : "failure.internal")
    }
    NSLog("Lino operation failed [%@]: %@", failure.code, failure.message)
    let key = "failure." + failure.code
    let message = localized(key)
    return message == key ? localized("failure.internal") : message
}
