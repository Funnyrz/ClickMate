import SwiftUI

struct TemplatesView: View {
    @EnvironmentObject private var store: PreferencesStore
    @State private var customExtension = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("templates.title"))
                .font(.title2.bold())
            Text(L10n.string("templates.description"))
                .foregroundStyle(.secondary)

            List {
                ForEach(Array(store.preferences.templates.enumerated()), id: \.element.id) { index, template in
                    SortableSettingsRow(index: index + 1) {
                        Text(template.localizedDisplayName)
                        Spacer()
                        Text(".\(template.fileExtension)")
                            .foregroundStyle(.secondary)
                        RemoveButton {
                            store.preferences.removeTemplate(id: template.id)
                        }
                    }
                }
                .onDelete { offsets in
                    let templateIDs = offsets.map { store.preferences.templates[$0].id }
                    for templateID in templateIDs {
                        store.preferences.removeTemplate(id: templateID)
                    }
                }
                .onMove { source, destination in
                    store.preferences.templates.move(fromOffsets: source, toOffset: destination)
                }
            }

            HStack {
                TextField(L10n.string("templates.customExtension"), text: $customExtension)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Button(L10n.string("templates.addTemplate")) {
                    addCustomTemplate()
                }
                .disabled(customExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(L10n.string("button.restoreRemoved")) {
                    store.preferences.restoreRemovedDefaults()
                }
                Spacer()
            }
        }
    }

    private func addCustomTemplate() {
        let cleanExtension = customExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !cleanExtension.isEmpty else { return }
        let template = FileTemplate(
            id: "custom-\(cleanExtension)-\(UUID().uuidString)",
            displayName: cleanExtension.uppercased(),
            fileExtension: cleanExtension,
            defaultBasename: "Untitled",
            contents: ""
        )
        store.preferences.templates.append(template)
        customExtension = ""
    }
}
