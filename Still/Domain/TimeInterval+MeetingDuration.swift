import Foundation

extension TimeInterval {
    var meetingDurationText: String {
        Duration.seconds(self).formatted(.time(pattern: .minuteSecond))
    }
}

