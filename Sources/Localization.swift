import AppKit
import Foundation

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Codable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: L("Light")
        case .dark: L("Dark")
        }
    }

    var appearanceName: NSAppearance.Name {
        switch self {
        case .light: .aqua
        case .dark: .darkAqua
        }
    }
}

enum Localization {
    static let languageDefaultsKey = "appLanguage"

    static func string(_ key: String, language: AppLanguage? = nil) -> String {
        let selectedLanguage = language ?? storedLanguage
        guard
            let path = Bundle.main.path(forResource: selectedLanguage.rawValue, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else { return key }

        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, arguments: [CVarArg]) -> String {
        let language = storedLanguage
        return String(
            format: string(key, language: language),
            locale: Locale(identifier: language.localeIdentifier),
            arguments: arguments
        )
    }

    private static var storedLanguage: AppLanguage {
        guard
            let rawValue = UserDefaults.standard.string(forKey: languageDefaultsKey),
            let language = AppLanguage(rawValue: rawValue)
        else { return .english }
        return language
    }
}

func L(_ key: String) -> String {
    Localization.string(key)
}

func LF(_ key: String, _ arguments: CVarArg...) -> String {
    Localization.format(key, arguments: arguments)
}
