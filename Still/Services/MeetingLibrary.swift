import Foundation
import SwiftData

@MainActor
protocol MeetingLibrary {
    func add(_ meeting: Meeting)
}

@MainActor
struct SwiftDataMeetingLibrary: MeetingLibrary {
    let context: ModelContext

    func add(_ meeting: Meeting) {
        context.insert(meeting)
    }
}
