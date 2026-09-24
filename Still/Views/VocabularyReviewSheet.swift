import SwiftUI

struct VocabularyReviewSheet: View {
    let changes: [VocabularyChange]
    let apply: ([VocabularyChange]) -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            List(changes) { change in
                VStack(alignment: .leading, spacing: 4) {
                    Text(change.before)
                        .strikethrough()
                        .foregroundStyle(.secondary)
                    Text(change.after)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("\(change.before) becomes \(change.after)"))
            }
            .navigationTitle("Apply Vocabulary")
            .safeAreaInset(edge: .bottom) {
                Text("Only the lines above change. Your own corrections, the audio and note sources stay as they are.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply \(changes.count) Changes") { apply(changes) }
                }
            }
        }
        .stillSheetWidth(mac: 520, minHeight: 420)
    }
}
