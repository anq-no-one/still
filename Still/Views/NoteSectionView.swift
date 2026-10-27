import SwiftUI

struct NoteSectionView: View {
    let title: String
    let items: [NoteItem]
    var speakerNames: (NoteItem) -> [String] = { _ in [] }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)

                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: item.isUserAuthored ? "pencil" : "quote.opening")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text)
                            let names = speakerNames(item)
                            if !names.isEmpty {
                                Text(names.formatted(.list(type: .and)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(.rect)
                    .accessibilityElement(children: .combine)
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") {
                            NoteClipboard.copy(item.text)
                        }
                    }
                }
            }
        }
    }
}
