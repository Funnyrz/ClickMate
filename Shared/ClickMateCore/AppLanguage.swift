import Foundation

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .system: return "language.system"
        case .english: return "language.english"
        case .simplifiedChinese: return "language.simplifiedChinese"
        }
    }

    var title: String {
        L10n.string(titleKey)
    }
}
