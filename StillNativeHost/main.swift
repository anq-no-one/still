import AppKit
import Foundation

let browserBundleID = NSRunningApplication(processIdentifier: getppid())?.bundleIdentifier
    .map(WebBrowser.bundleID(owning:))
let input = FileHandle.standardInput
let output = FileHandle.standardOutput
var reader = NativeMessageReader()

while true {
    let chunk = input.availableData
    guard !chunk.isEmpty, let messages = try? reader.append(chunk) else { break }

    for message in messages {
        if let event = BrowserMeetingSignal.event(fromExtensionMessage: message, browserBundleID: browserBundleID) {
            BrowserMeetingSignal.post(event)
        }
        output.write(NativeMessageFrame.acknowledgement)
    }
}
