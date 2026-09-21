import SwiftUI

struct NoteSectionView: View {
    let title: String
    let items: [NoteItem]
    let openEvidence: (NoteItem) -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)

                ForEach(items) { item in
                    Button {
                        openEvidence(item)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: item.isUserAuthored ? "pencil" : "quote.opening")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(item.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Plays the transcript this came from")
                }
            }
        }
    }
}
