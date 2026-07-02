import SwiftUI

struct MenusView: View {
    @EnvironmentObject private var store: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("menus.title"))
                .font(.title2.bold())
            Text(L10n.string("menus.description"))
                .foregroundStyle(.secondary)

            List {
                ForEach(Array(store.preferences.orderedMenuCommands.enumerated()), id: \.element.id) { index, command in
                    SortableSettingsRow(index: index + 1) {
                        Toggle(command.title, isOn: binding(for: command))
                    }
                }
                .onMove { source, destination in
                    store.preferences.menuCommandOrder = store.preferences.orderedMenuCommands
                    store.preferences.menuCommandOrder.move(fromOffsets: source, toOffset: destination)
                }
            }

            HStack {
                Button(L10n.string("button.enableAll")) {
                    store.preferences.enabledCommands = Set(MenuCommand.allCases)
                    store.preferences.menuCommandOrder = store.preferences.orderedMenuCommands
                }
                Button(L10n.string("button.resetDefaults")) {
                    store.reset()
                }
                Spacer()
            }
        }
    }

    private func binding(for command: MenuCommand) -> Binding<Bool> {
        Binding {
            store.preferences.enabledCommands.contains(command)
        } set: { isEnabled in
            if isEnabled {
                store.preferences.enabledCommands.insert(command)
            } else {
                store.preferences.enabledCommands.remove(command)
            }
        }
    }
}

struct SortableSettingsRow<Content: View>: View {
    let index: Int
    private let content: Content

    init(index: Int, @ViewBuilder content: () -> Content) {
        self.index = index
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index)")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 24)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 8) {
                content
            }
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 28, height: 24)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
