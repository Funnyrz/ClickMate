import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: PreferencesStore
    @EnvironmentObject private var updateCoordinator: UpdateCheckCoordinator
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

            updateFooter
        }
        .padding()
        .id(store.preferences.language)
        .onAppear {
            if !store.preferences.hasDismissedPermissionGuide {
                selectedTab = .permissions
            }
        }
        .alert(item: manualResultBinding, content: updateAlert)
    }

    private var updateFooter: some View {
        HStack(spacing: 8) {
            let version = AppVersion.displayString()
            if !version.isEmpty {
                Text(version)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            switch updateCoordinator.state {
            case .checking:
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("update.checking"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let .updateAvailable(release):
                Button(L10n.string("update.availableInline", release.normalizedVersion ?? release.tagName)) {
                    openRelease(release)
                }
                .buttonStyle(.link)
            case .idle, .upToDate, .failed:
                EmptyView()
            }

            Button(L10n.string("update.check")) {
                Task {
                    await updateCoordinator.checkManually()
                }
            }
            .disabled(updateCoordinator.state == .checking)
        }
        .frame(maxWidth: .infinity)
    }

    private var manualResultBinding: Binding<ManualUpdateCheckResult?> {
        Binding(
            get: { updateCoordinator.manualResult },
            set: { result in
                if result == nil {
                    updateCoordinator.dismissManualResult()
                }
            }
        )
    }

    private func updateAlert(for result: ManualUpdateCheckResult) -> Alert {
        switch result {
        case let .upToDate(version):
            return Alert(
                title: Text(L10n.string("update.alertUpToDateTitle")),
                message: Text(L10n.string("update.alertUpToDateMessage", version)),
                dismissButton: .default(Text(L10n.string("update.close")))
            )
        case let .updateAvailable(currentVersion, release):
            let latestVersion = release.normalizedVersion ?? release.tagName
            return Alert(
                title: Text(L10n.string("update.alertAvailableTitle")),
                message: Text(L10n.string("update.alertAvailableMessage", latestVersion, currentVersion)),
                primaryButton: .default(Text(L10n.string("update.openDownload"))) {
                    openRelease(release)
                },
                secondaryButton: .cancel(Text(L10n.string("update.later")))
            )
        case .failed:
            return Alert(
                title: Text(L10n.string("update.alertFailedTitle")),
                message: Text(L10n.string("update.alertFailedMessage")),
                primaryButton: .default(Text(L10n.string("update.openReleases"))) {
                    NSWorkspace.shared.open(GitHubRelease.fallbackDownloadURL)
                },
                secondaryButton: .cancel(Text(L10n.string("update.close")))
            )
        }
    }

    private func openRelease(_ release: GitHubRelease) {
        NSWorkspace.shared.open(release.safeDownloadURL)
    }
}

private enum SettingsTab {
    case menus
    case layout
    case templates
    case apps
    case permissions
}
