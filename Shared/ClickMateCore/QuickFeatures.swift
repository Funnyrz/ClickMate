import Foundation

enum QuickFeatureID: String, Codable, CaseIterable, Hashable {
    case finderCut
    case screenshot
}

struct KeyboardShortcut: Codable, Equatable, Hashable {
    struct Modifiers: OptionSet, Codable, Hashable {
        let rawValue: UInt8

        static let command = Modifiers(rawValue: 1 << 0)
        static let control = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)
        static let shift = Modifiers(rawValue: 1 << 3)

        static let supported: Modifiers = [.command, .control, .option, .shift]

        init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.init(rawValue: try container.decode(UInt8.self))
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        var isValid: Bool {
            !isEmpty
                && subtracting(Self.supported).isEmpty
                && !intersection([.command, .control]).isEmpty
        }

        var displayString: String {
            var result = ""
            if contains(.control) { result += "⌃" }
            if contains(.option) { result += "⌥" }
            if contains(.shift) { result += "⇧" }
            if contains(.command) { result += "⌘" }
            return result
        }
    }

    var keyCode: UInt16
    var modifiers: Modifiers

    init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    static let commandX = KeyboardShortcut(keyCode: 7, modifiers: .command)
    static let legacyScreenshotDefault = KeyboardShortcut(keyCode: 0, modifiers: [.command, .control])
    static let commandControlS = KeyboardShortcut(keyCode: 1, modifiers: [.command, .control])
    static let finderCutDefault = commandX
    static let screenshotDefault = commandControlS

    var displayString: String {
        modifiers.displayString + Self.displayName(for: keyCode)
    }

    var isValid: Bool {
        keyCode <= Self.maximumKeyCode
            && !Self.modifierKeyCodes.contains(keyCode)
            && modifiers.isValid
    }

    func conflicts(with other: KeyboardShortcut) -> Bool {
        isValid && other.isValid && self == other
    }

    private static let maximumKeyCode: UInt16 = 127
    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    private static func displayName(for keyCode: UInt16) -> String {
        keyDisplayNames[keyCode] ?? "Key \(keyCode)"
    }

    private static let keyDisplayNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y",
        17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=",
        25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U",
        33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K",
        41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥",
        49: "Space", 50: "`", 51: "⌫", 53: "⎋", 64: "F17", 65: ".", 67: "*",
        69: "+", 71: "Clear", 75: "/", 76: "⌤", 78: "-", 79: "F18", 80: "F19",
        81: "=", 82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6",
        89: "7", 90: "F20", 91: "8", 92: "9", 96: "F5", 97: "F6", 98: "F7",
        99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16",
        107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help", 115: "↖",
        116: "⇞", 117: "⌦", 118: "F4", 119: "↘", 120: "F2", 121: "⇟", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}

struct QuickFeatureSettings: Codable, Equatable, Hashable, Identifiable {
    var id: QuickFeatureID
    var isEnabled: Bool
    var shortcut: KeyboardShortcut

    init(id: QuickFeatureID, isEnabled: Bool = false, shortcut: KeyboardShortcut? = nil) {
        self.id = id
        self.isEnabled = isEnabled
        self.shortcut = shortcut ?? Self.defaultShortcut(for: id)
    }

    static let defaults = QuickFeatureID.allCases.map {
        QuickFeatureSettings(id: $0)
    }

    static func defaultShortcut(for id: QuickFeatureID) -> KeyboardShortcut {
        switch id {
        case .finderCut:
            return .finderCutDefault
        case .screenshot:
            return .screenshotDefault
        }
    }

    static func normalized(_ settings: [QuickFeatureSettings]) -> [QuickFeatureSettings] {
        var settingsByID: [QuickFeatureID: QuickFeatureSettings] = [:]
        for setting in settings where settingsByID[setting.id] == nil {
            settingsByID[setting.id] = setting
        }
        return QuickFeatureID.allCases.map { id in
            settingsByID[id] ?? QuickFeatureSettings(id: id)
        }
    }

    static func conflictingFeatureIDs(in settings: [QuickFeatureSettings]) -> Set<QuickFeatureID> {
        let enabledSettings = normalized(settings).filter { $0.isEnabled && $0.shortcut.isValid }
        let settingsByShortcut = Dictionary(grouping: enabledSettings, by: \.shortcut)
        return Set(
            settingsByShortcut.values
                .filter { $0.count > 1 }
                .flatMap { $0.map(\.id) }
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case isEnabled
        case shortcut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(QuickFeatureID.self, forKey: .id)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        let decodedShortcut = try container.decodeIfPresent(KeyboardShortcut.self, forKey: .shortcut)
        if let decodedShortcut, decodedShortcut.isValid {
            shortcut = decodedShortcut
        } else {
            shortcut = Self.defaultShortcut(for: id)
        }
    }
}

struct LossyQuickFeatureSettings: Decodable {
    let values: [QuickFeatureSettings]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [QuickFeatureSettings] = []
        while !container.isAtEnd {
            let elementDecoder = try container.superDecoder()
            if let value = try? QuickFeatureSettings(from: elementDecoder) {
                values.append(value)
            }
        }
        self.values = values
    }
}

struct ScreenshotSettings: Codable, Equatable {
    var copiesToClipboard: Bool
    var savesToDesktop: Bool

    init(copiesToClipboard: Bool = true, savesToDesktop: Bool = false) {
        self.copiesToClipboard = copiesToClipboard
        self.savesToDesktop = savesToDesktop
    }

    static let defaults = ScreenshotSettings()

    private enum CodingKeys: String, CodingKey {
        case copiesToClipboard
        case savesToDesktop
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        copiesToClipboard = try container.decodeIfPresent(Bool.self, forKey: .copiesToClipboard) ?? true
        savesToDesktop = try container.decodeIfPresent(Bool.self, forKey: .savesToDesktop) ?? false
    }
}
