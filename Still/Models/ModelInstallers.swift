import Foundation

@MainActor
struct ModelInstallers {
    let transcription: ModelPackInstaller
    let speakers: ModelPackInstaller
    let meetingMemory: ModelPackInstaller

    var downloadSizeText: String {
        ByteCountFormatStyle(style: .file).format(Int64(transcription.pack.totalBytes + speakers.pack.totalBytes))
    }

    var isInstalling: Bool {
        [transcription, speakers, meetingMemory].contains { installer in
            if case .installing = installer.state { return true }
            return installer.state == .verifying
        }
    }

    func resumeIfApproved() async {
        await transcription.resumeIfApproved()
        await speakers.resumeIfApproved()
        await meetingMemory.resumeIfApproved()
    }

    func approveAndInstall() async {
        await transcription.approveAndInstall()
        await speakers.approveAndInstall()
    }
}
