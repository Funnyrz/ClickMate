import SwiftUI

struct MenuLayoutView: View {
    @EnvironmentObject private var store: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("layout.title"))
                .font(.title2.bold())
            Text(L10n.string("layout.description"))
                .foregroundStyle(.secondary)

            List {
                ForEach(store.preferences.orderedVisibleMenuGroups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.title)
                                Text(statusText(for: group))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle(L10n.string("layout.foldIntoApp"), isOn: foldedBinding(for: group))
                                .toggleStyle(.switch)
                        }

                        shortcutControls(for: group)
                            .padding(.leading, 20)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func shortcutControls(for group: MenuCommandGroup) -> some View {
        if group == .newFile {
            ForEach(MenuLayoutPolicy.shortcutTemplateCandidates(for: store.preferences)) { template in
                shortcutToggle(template.localizedDisplayName, isOn: templateShortcutBinding(for: template.id))
            }
        } else {
            ForEach(MenuLayoutPolicy.shortcutCommandCandidates(for: group, preferences: store.preferences)) { command in
                shortcutToggle(command.title, isOn: commandShortcutBinding(for: command))
            }
        }
    }

    private func shortcutToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(L10n.string("layout.topLevelShortcut"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }

    private func foldedBinding(for group: MenuCommandGroup) -> Binding<Bool> {
        Binding {
            store.preferences.foldedMenuGroups.contains(group)
        } set: { isFolded in
            if isFolded {
                store.preferences.foldedMenuGroups.insert(group)
            } else {
                store.preferences.foldedMenuGroups.remove(group)
            }
        }
    }

    private func statusText(for group: MenuCommandGroup) -> String {
        store.preferences.foldedMenuGroups.contains(group)
            ? L10n.string("layout.statusFolded")
            : L10n.string("layout.statusTopLevel")
    }

    private func commandShortcutBinding(for command: MenuCommand) -> Binding<Bool> {
        Binding {
            store.preferences.topLevelShortcutCommands.contains(command)
        } set: { isEnabled in
            if isEnabled {
                store.preferences.topLevelShortcutCommands.insert(command)
            } else {
                store.preferences.topLevelShortcutCommands.remove(command)
            }
        }
    }

    private func templateShortcutBinding(for templateID: String) -> Binding<Bool> {
        Binding {
            store.preferences.topLevelShortcutTemplateIDs.contains(templateID)
        } set: { isEnabled in
            if isEnabled {
                store.preferences.topLevelShortcutTemplateIDs.insert(templateID)
            } else {
                store.preferences.topLevelShortcutTemplateIDs.remove(templateID)
            }
        }
    }
}
