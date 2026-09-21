import Foundation

extension TimeInterval {
    var recordingDurationText: String {
        Duration.seconds(self).formatted(.time(pattern: .minuteSecond))
    }
}
