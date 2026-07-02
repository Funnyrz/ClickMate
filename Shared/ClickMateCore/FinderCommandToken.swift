import Foundation

enum FinderCommandToken: Equatable {
    case command(MenuCommand)
    case template(String)
    case pinnedApplication(String)

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "command":
            guard let command = MenuCommand(rawValue: parts[1]) else { return nil }
            self = .command(command)
        case "template":
            self = .template(parts[1])
        case "pinned":
            self = .pinnedApplication(parts[1])
        default:
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .command(let command):
            return "command:\(command.rawValue)"
        case .template(let id):
            return "template:\(id)"
        case .pinnedApplication(let path):
            return "pinned:\(path)"
        }
    }
}
