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
                    .padding(.vertical, 4)
                }
            }
        }
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
}
