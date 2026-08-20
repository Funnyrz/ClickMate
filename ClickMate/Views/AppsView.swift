import SwiftUI

struct AppsView: View {
    @EnvironmentObject private var store: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("apps.title"))
                .font(.title2.bold())
            Text(L10n.string("apps.description"))
                .foregroundStyle(.secondary)

            List {
                Section(L10n.string("apps.detected")) {
                    ForEach(Array(detectedApps.enumerated()), id: \.element.id) { index, app in
                        SortableSettingsRow(index: index + 1) {
                            Image(systemName: app.path == nil ? "circle" : "checkmark.circle.fill")
                                .foregroundStyle(app.path == nil ? Color.secondary : Color.green)
                            Text(app.displayName)
                            Spacer()
                            Text(app.path ?? L10n.string("apps.notInstalled"))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            RemoveButton {
                                store.preferences.removeDetectedApplication(bundleIdentifier: app.bundleIdentifier)
                            }
                        }
                    }
                    .onMove { source, destination in
                        store.preferences.detectedApplicationOrder = store.preferences.orderedDetectedApplicationBundleIDs
                        store.preferences.detectedApplicationOrder.move(fromOffsets: source, toOffset: destination)
                    }
                }

                Section(L10n.string("apps.pinned")) {
                    ForEach(Array(store.preferences.pinnedApplicationPaths.enumerated()), id: \.element) { index, path in
                        SortableSettingsRow(index: index + 1) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                                Text(path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            RemoveButton {
                                store.preferences.pinnedApplicationPaths.removeAll { $0 == path }
                            }
                        }
                    }
                    .onDelete { offsets in
                        store.preferences.pinnedApplicationPaths.remove(atOffsets: offsets)
                    }
                    .onMove { source, destination in
                        store.preferences.pinnedApplicationPaths.move(fromOffsets: source, toOffset: destination)
                    }
                }
            }

            HStack {
                Button(L10n.string("button.refresh")) {
                    store.preferences.detectedApplicationOrder = store.preferences.detectedApplicationOrder
                }
                Button(L10n.string("apps.pinApplication")) {
                    pinApplication()
                }
                Button(L10n.string("button.restoreRemoved")) {
                    store.preferences.restoreRemovedDefaults()
                }
                Spacer()
            }
        }
    }

    private var detectedApps: [DetectedApplication] {
        AppDetector.detectedApplications(
            order: store.preferences.detectedApplicationOrder,
            removedBundleIdentifiers: store.preferences.removedDetectedApplicationBundleIDs
        )
    }

    private func pinApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            let paths = store.preferences.pinnedApplicationPaths + [url.path]
            store.preferences.pinnedApplicationPaths = PinnedApplicationPathPolicy.normalizedPaths(paths)
        }
    }
}
