import Foundation

@MainActor
struct ModelInstallers {
    let transcription: ModelPackInstaller
    let speakers: ModelPackInstaller

    var downloadSizeText: String {
        ByteCountFormatStyle(style: .file).format(Int64(transcription.pack.totalBytes + speakers.pack.totalBytes))
    }

    func approveAndInstall() async {
        await transcription.approveAndInstall()
        await speakers.approveAndInstall()
    }
}
