import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: PreferencesStore

    var body: some View {
        TabView {
            MenusView()
                .tabItem { Label(L10n.string("tab.menus"), systemImage: "list.bullet.rectangle") }
            MenuLayoutView()
                .tabItem { Label(L10n.string("tab.layout"), systemImage: "rectangle.split.2x1") }
            TemplatesView()
                .tabItem { Label(L10n.string("tab.templates"), systemImage: "doc.badge.plus") }
            AppsView()
                .tabItem { Label(L10n.string("tab.apps"), systemImage: "terminal") }
            PermissionsView()
                .tabItem { Label(L10n.string("tab.permissions"), systemImage: "checkmark.shield") }
        }
        .padding()
        .id(store.preferences.language)
    }
}
