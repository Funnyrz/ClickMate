import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: PreferencesStore
    @State private var selectedTab: SettingsTab = .menus

    var body: some View {
        VStack(spacing: 10) {
            TabView(selection: $selectedTab) {
                MenusView()
                    .tabItem { Label(L10n.string("tab.menus"), systemImage: "list.bullet.rectangle") }
                    .tag(SettingsTab.menus)
                MenuLayoutView()
                    .tabItem { Label(L10n.string("tab.layout"), systemImage: "rectangle.split.2x1") }
                    .tag(SettingsTab.layout)
                TemplatesView()
                    .tabItem { Label(L10n.string("tab.templates"), systemImage: "doc.badge.plus") }
                    .tag(SettingsTab.templates)
                AppsView()
                    .tabItem { Label(L10n.string("tab.apps"), systemImage: "terminal") }
                    .tag(SettingsTab.apps)
                PermissionsView()
                    .tabItem { Label(L10n.string("tab.permissions"), systemImage: "checkmark.shield") }
                    .tag(SettingsTab.permissions)
            }

            let version = AppVersion.displayString()
            if !version.isEmpty {
                Text(version)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding()
        .id(store.preferences.language)
        .onAppear {
            if !store.preferences.hasDismissedPermissionGuide {
                selectedTab = .permissions
            }
        }
    }
}

private enum SettingsTab {
    case menus
    case layout
    case templates
    case apps
    case permissions
}
