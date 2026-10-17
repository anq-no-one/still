import Foundation

enum DetailFallback {
    static func recording(selected: Recording.ID?, recordings: [Recording]) -> Recording? {
        if let selected, let match = recordings.first(where: { $0.id == selected }) {
            return match
        }
        return recordings.first
    }
}
