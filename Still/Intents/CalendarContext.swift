import EventKit
import Foundation

struct MeetingContext: Equatable, Sendable {
    let title: String
    let participants: [String]
}

@MainActor
protocol CalendarSource {
    func hasAccess() async -> Bool
    func requestAccess() async -> Bool
    func events(around date: Date) async -> [MeetingContext]
}

/// Suggests a title and the people expected in the room, but only after the
/// user grants calendar access. Without it, Still simply has nothing to suggest.
@MainActor
struct CalendarContext {
    let source: CalendarSource
    let window: TimeInterval

    init(source: CalendarSource, window: TimeInterval = 900) {
        self.source = source
        self.window = window
    }

    func suggestion(at date: Date) async -> MeetingContext? {
        guard await source.hasAccess() else { return nil }

        return await source.events(around: date).first
    }
}

@MainActor
struct EventKitCalendarSource: CalendarSource {
    private let store = EKEventStore()

    func hasAccess() async -> Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func events(around date: Date) async -> [MeetingContext] {
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-900),
            end: date.addingTimeInterval(900),
            calendars: nil
        )

        return store.events(matching: predicate).map { event in
            MeetingContext(
                title: event.title ?? "",
                participants: (event.attendees ?? []).filter { !$0.isCurrentUser }.compactMap(\.name)
            )
        }
    }
}
