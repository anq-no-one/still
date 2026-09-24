import SwiftUI

struct VocabularyEditorView: View {
    let library: Library
    let project: Project

    @State private var vocabulary: ProjectVocabulary
    @State private var newTerm = ""
    @State private var newVariants = ""
    @Environment(\.dismiss) private var dismiss

    init(library: Library, project: Project) {
        self.library = library
        self.project = project
        _vocabulary = State(initialValue: library.vocabulary(forProject: project.id))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(vocabulary.activeTerms) { term in
                        VocabularyTermRow(term: term, save: save, delete: delete)
                    }
                } header: {
                    Text("Terms")
                } footer: {
                    Text(
                        "Still replaces a misheard variant with your spelling in new recordings for \(project.name)." +
                        " It never changes a recording you already made."
                    )
                }

                Section {
                    TextField("Term", text: $newTerm)
                    TextField("Variants, comma or line separated", text: $newVariants, axis: .vertical)
                        .lineLimit(2...4)
                    Button("Add Term", action: addTerm)
                        .disabled(trimmedNewTerm.isEmpty)
                } header: {
                    Text("New Term")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Vocabulary")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var trimmedNewTerm: String {
        newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addTerm() {
        guard !trimmedNewTerm.isEmpty else { return }

        vocabulary.upsert(VocabularyTerm(term: trimmedNewTerm, variants: Self.splitVariants(newVariants)))
        persist()
        newTerm = ""
        newVariants = ""
    }

    private func save(_ term: VocabularyTerm) {
        vocabulary.upsert(term)
        persist()
    }

    private func delete(_ term: VocabularyTerm) {
        vocabulary.delete(term.id)
        persist()
    }

    private func persist() {
        try? library.saveVocabulary(vocabulary)
    }

    static func splitVariants(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",\n"))
    }
}

private struct VocabularyTermRow: View {
    let term: VocabularyTerm
    let save: (VocabularyTerm) -> Void
    let delete: (VocabularyTerm) -> Void

    @State private var name: String
    @State private var variantsText: String

    init(term: VocabularyTerm, save: @escaping (VocabularyTerm) -> Void, delete: @escaping (VocabularyTerm) -> Void) {
        self.term = term
        self.save = save
        self.delete = delete
        _name = State(initialValue: term.term)
        _variantsText = State(initialValue: term.variants.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Term", text: $name)
                    .onSubmit(renameIfNeeded)
                Button(role: .destructive) {
                    delete(term)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Delete \(term.term)"))
            }

            TextField("Variants, comma or line separated", text: $variantsText, axis: .vertical)
                .lineLimit(1...3)
                .font(.caption)
                .foregroundStyle(.secondary)
                .onSubmit(updateVariantsIfNeeded)
        }
        .onChange(of: term) { _, value in
            name = value.term
            variantsText = value.variants.joined(separator: ", ")
        }
        .onChange(of: variantsText) { _, _ in updateVariantsIfNeeded() }
    }

    private func renameIfNeeded() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != term.term else {
            name = term.term
            return
        }

        var updated = term
        updated.rename(to: trimmed)
        save(updated)
    }

    private func updateVariantsIfNeeded() {
        let variants = VocabularyEditorView.splitVariants(variantsText)
        guard VocabularyTerm.normalized(variants, excluding: term.term) != term.variants else { return }

        var updated = term
        updated.setVariants(variants)
        save(updated)
    }
}
