import Foundation
import OpenBarCore

enum Localization {
    static var selectedLanguage: AppLanguage {
        AppLanguage(
            rawValue: UserDefaults.standard.string(forKey: "OpenBar.Language") ?? ""
        ) ?? .system
    }

    static var resolvedLanguage: AppLanguage {
        switch selectedLanguage {
        case .system:
            return Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
                ? .simplifiedChinese
                : .english
        case .english: return .english
        case .simplifiedChinese: return .simplifiedChinese
        }
    }

    static func string(_ key: String) -> String {
        let language = selectedLanguage
        let code: String?
        switch language {
        case .system: code = nil
        case .english: code = "en"
        case .simplifiedChinese: code = "zh-Hans"
        }

        guard let code,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            return NSLocalizedString(key, bundle: .main, comment: "")
        }
        return NSLocalizedString(key, bundle: bundle, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale.current, arguments: arguments)
    }
}

extension ManagedMenuBarItem {
    var localizedDisplayName: String {
        MenuBarProductName.localized(
            bundleIdentifier: bundleIdentifier,
            semanticIdentifier: semanticIdentifier,
            fallback: displayName
        )
    }
}

private enum MenuBarProductName {
    static func localized(
        bundleIdentifier: String,
        semanticIdentifier: String,
        fallback: String
    ) -> String {
        if semanticIdentifier.hasPrefix("module:") {
            return MenuBarItemPresentation.moduleDisplayName(
                String(semanticIdentifier.dropFirst("module:".count))
            )
        }

        let chinese = Localization.resolvedLanguage == .simplifiedChinese
        switch bundleIdentifier {
        case "com.tencent.xinWeChat": return chinese ? "微信" : "WeChat"
        case "com.netease.uuremote": return chinese ? "UU远程" : "UU Remote"
        case "com.apple.TextInputMenuAgent": return chinese ? "输入法" : "Input Menu"
        case "com.apple.systemuiserver": return chinese ? "系统界面" : "System UI"
        case "com.apple.Spotlight": return chinese ? "聚焦" : "Spotlight"
        case "com.apple.campo": return "Siri"
        case "com.openai.codex": return "ChatGPT"
        case "com.woniuniuniu.OpenBar": return L("Open Bar Brand")
        case "com.lemon.lvpro": return chinese ? "视频融合" : "VideoFusion"
        case "cn.better365.iShotHelper": return "iShot"
        case "com.microsoft.OneDrive": return "OneDrive"
        case "com.getdropbox.dropbox": return "Dropbox"
        case "com.getcleanshot.app-setapp": return "CleanShot X"
        case "com.wiheads.paste-setapp": return "Paste"
        case "com.ccswitch.desktop": return "CC Switch"
        case "com.nssurge.surge-mac": return "Surge"
        case "com.todesktop.230313mzl4w4u92": return "Cursor"
        case "at.EternalStorms.Yoink-setapp": return "Yoink"
        case "now.typeless.desktop": return "Typeless"
        case "com.parall.app": return "Parall"
        case "com.setapp.DesktopClient.SetappLauncher": return "Setapp"
        case "studio.zooms": return "Screen Studio"
        default: return fallback
        }
    }
}

func L(_ key: String) -> String { Localization.string(key) }
func LF(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: arguments)
}

extension ItemSection {
    var localizedTitle: String {
        switch self {
        case .shown: L("Shown")
        case .hidden: L("Hidden")
        case .alwaysHidden: L("Always Hidden")
        }
    }

    var localizedSubtitle: String {
        switch self {
        case .shown: L("Stays in the menu bar")
        case .hidden: L("Appears when OPEN BAR is expanded")
        case .alwaysHidden: L("Remains out of sight when expanded")
        }
    }

    var symbol: String {
        switch self {
        case .shown: "eye"
        case .hidden: "eye.slash"
        case .alwaysHidden: "archivebox"
        }
    }
}

extension AppLanguage {
    var localizedTitle: String {
        switch self {
        case .system: L("System")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }
}

extension AppearancePreference {
    var localizedTitle: String {
        switch self {
        case .system: L("System")
        case .light: L("Light")
        case .dark: L("Dark")
        }
    }
}
