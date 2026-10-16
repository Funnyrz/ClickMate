import SwiftUI

struct TemplatesView: View {
    @EnvironmentObject private var store: PreferencesStore
    @State private var editor: TemplateEditorPresentation?

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
                        Text(template.fileExtension.isEmpty ? L10n.string("templates.noExtension") : ".\(template.fileExtension)")
                            .foregroundStyle(.secondary)
                        Button {
                            editor = TemplateEditorPresentation(template: template, isNew: false)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.string("templates.edit"))
                        .accessibilityLabel(L10n.string("templates.edit"))
                        .accessibilityIdentifier("template-edit-\(template.id)")
                        Button {
                            editor = TemplateEditorPresentation(template: template.duplicated(), isNew: true)
                        } label: {
                            Image(systemName: "square.on.square")
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.string("templates.duplicate"))
                        .accessibilityLabel(L10n.string("templates.duplicate"))
                        .accessibilityIdentifier("template-duplicate-\(template.id)")
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
            .frame(minHeight: 0, maxHeight: .infinity)
            .layoutPriority(-1)

            HStack {
                Button(L10n.string("templates.addTemplate")) {
                    editor = TemplateEditorPresentation(
                        template: FileTemplate(
                            id: "custom-\(UUID().uuidString)",
                            displayName: L10n.string("templates.newName"),
                            fileExtension: "",
                            defaultBasename: L10n.string("templates.untitled"),
                            contents: ""
                        ),
                        isNew: true
                    )
                }
                .accessibilityIdentifier("template-add-button")
                Button(L10n.string("button.restoreRemoved")) {
                    store.preferences.restoreRemovedDefaults()
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $editor) { presentation in
            FileTemplateEditorView(template: presentation.template, isNew: presentation.isNew) { template in
                if presentation.isNew {
                    store.preferences.templates.append(template)
                } else if let index = store.preferences.templates.firstIndex(where: { $0.id == template.id }) {
                    store.preferences.templates[index] = template
                }
            }
        }
    }
}

private struct TemplateEditorPresentation: Identifiable {
    let id = UUID()
    let template: FileTemplate
    let isNew: Bool
}

struct FileTemplateEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FileTemplate
    private let originalTemplate: FileTemplate
    private let initialDisplayName: String
    private let isNew: Bool
    private let onSave: (FileTemplate) -> Void

    init(template: FileTemplate, isNew: Bool, onSave: @escaping (FileTemplate) -> Void) {
        originalTemplate = template
        initialDisplayName = template.localizedDisplayName
        var localizedDraft = template
        localizedDraft.displayName = template.localizedDisplayName
        _draft = State(initialValue: localizedDraft)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string(isNew ? "templates.newTitle" : "templates.editTitle"))
                .font(.title2.bold())

            Form {
                TextField(L10n.string("templates.displayName"), text: $draft.displayName)
                    .accessibilityIdentifier("template-name-field")
                TextField(L10n.string("templates.basename"), text: $draft.defaultBasename)
                    .accessibilityIdentifier("template-basename-field")
                TextField(L10n.string("templates.extensionOptional"), text: $draft.fileExtension)
                    .accessibilityIdentifier("template-extension-field")
                LabeledContent(L10n.string("templates.filenamePreview")) {
                    Text(draft.filename)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            .textFieldStyle(.roundedBorder)

            Text(L10n.string("templates.contents"))
                .font(.headline)
            TextEditor(text: $draft.contents)
                .font(.system(.body, design: .monospaced))
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
                .frame(minHeight: 180)
                .accessibilityIdentifier("template-content-editor")

            if let error = draft.validationError {
                Text(error.localizedDescription)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("template-validation-message")
            }

            HStack {
                Spacer()
                Button(L10n.string("button.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("button.save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.validationError != nil)
                    .accessibilityIdentifier("template-save-button")
            }
        }
        .padding(24)
        .frame(width: 620, height: 640)
    }

    private func save() {
        guard draft.validationError == nil else { return }
        var saved = draft
        // Keep an unchanged built-in name localizable when only its content or filename changed.
        if saved.displayName == initialDisplayName {
            saved.displayName = originalTemplate.displayName
        }
        onSave(saved)
        dismiss()
    }
}
