import SwiftUI

enum EvidencePlayback {
    static func shouldPause(tapped: NoteItem.ID, playingID: NoteItem.ID?, playerIsPlaying: Bool) -> Bool {
        playingID == tapped && playerIsPlaying
    }

    static func isShowingPlaying(_ id: NoteItem.ID, playingID: NoteItem.ID?, playerIsPlaying: Bool) -> Bool {
        playingID == id && playerIsPlaying
    }
}

struct NoteSectionView: View {
    let title: String
    let items: [NoteItem]
    let player: RecordingPlayer
    let playingID: NoteItem.ID?
    let toggleEvidence: (NoteItem) -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)

                ForEach(items) { item in
                    Button {
                        toggleEvidence(item)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: item.isUserAuthored ? "pencil" : "quote.opening")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(item.text)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if EvidencePlayback.isShowingPlaying(item.id, playingID: playingID, playerIsPlaying: player.isPlaying) {
                                Image(systemName: "waveform")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Playing this evidence")
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Plays or pauses the transcript this came from")
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
