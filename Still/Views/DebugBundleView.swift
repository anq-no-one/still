import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// TestFlight-only developer tooling, so its text is English and stays out of
/// the translated string catalog.
struct DebugBundleView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case given
        case latest
        case lastFive
        case all
        case none

        var id: String { rawValue }
    }

    let builder: DebugBundleBuilder
    let library: Library
    let courier: BugReportCourier?
    let markers: ProblemMarkers?
    let givenRecordingID: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var scope: Scope
    @State private var includesAudio = true
    @State private var note = ""
    @State private var attachments: [BugReportAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isImportingImages = false
    @State private var isPickingPhotos = false
    @State private var step: String?
    @State private var bundle: URL?
    @State private var problem: String?
    @State private var saved: String?
    @State private var markedAt: Date?
    @State private var savedBundles: [SavedBundle] = []
    @FocusState private var isWritingNote: Bool

    private let store = DebugBundleStore(directory: DebugBundleStore.bundlesDirectory)

    init(builder: DebugBundleBuilder, library: Library, courier: BugReportCourier? = nil, markers: ProblemMarkers? = nil, recordingID: UUID? = nil) {
        self.builder = builder
        self.library = library
        self.courier = courier
        self.markers = markers
        givenRecordingID = recordingID
        _scope = State(initialValue: recordingID == nil ? .latest : .given)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String("What went wrong?"), text: $note, prompt: Text(verbatim: "What did you do, and what happened?"), axis: .vertical)
                        .lineLimit(3...8)
                        .focused($isWritingNote)
                        .accessibilityIdentifier("bugReport.note")
                } header: {
                    Text(verbatim: "What Happened")
                }

                Section {
                    attachmentList
                    attachmentButtons
                } footer: {
                    Text(verbatim: "Attach screenshots or photos of what you saw.")
                }

                Section {
                    Button(String("Mark This Moment"), systemImage: "flag", action: mark)
                    if let markedAt {
                        LabeledContent(String("Marked at"), value: markedAt.formatted(date: .omitted, time: .standard))
                    }
                } footer: {
                    Text(verbatim: "Keeps every thread, the memory and the app's state as they are now, even if you send the report later.")
                }

                Section {
                    Picker(String("Recordings"), selection: $scope) {
                        ForEach(scopes) { scope in
                            Text(verbatim: label(scope)).tag(scope)
                        }
                    }
                    Toggle(String("Include original audio tracks"), isOn: $includesAudio)
                } footer: {
                    Text(verbatim: "The bundle holds the developer log, timings, main-thread hangs with stacks, CPU, memory and thread samples, crashes, MetricKit reports, this launch's system log, and for each recording its original audio, transcript, note, extracted memory and every on-device model prompt and answer.")
                }

                Section {
                    if let step {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(verbatim: step)
                        }
                        .accessibilityElement(children: .combine)
                    } else {
                        if courier != nil {
                            Button(String("Submit Bug Report"), systemImage: "paperplane") { prepare(submitting: true) }
                                .accessibilityIdentifier("bugReport.submit")
                        }
                        Button(String("Save Debug Bundle"), systemImage: "ladybug") { prepare(submitting: false) }
                            .accessibilityIdentifier("bugReport.save")
                    }
                    sendStatus
                    if let bundle {
                        ShareLink(item: bundle, preview: SharePreview(bundle.lastPathComponent)) {
                            Label(String("Share \(bundle.lastPathComponent)"), systemImage: "square.and.arrow.up")
                        }
                    }
                    if let saved {
                        Label(saved, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text(verbatim: submitFooter)
                }

                if !savedBundles.isEmpty {
                    Section(String("Saved Bundles")) {
                        ForEach(savedBundles) { saved in
                            SavedBundleRow(bundle: saved) {
                                store.delete(saved)
                                savedBundles = store.bundles()
                            }
                        }
                    }
                }

                if let courier, courier.offersReceiving {
                    BugReportInboxSection(courier: courier)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String("Report a Problem"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .photosPicker(isPresented: $isPickingPhotos, selection: $photoItems, maxSelectionCount: 6, matching: .images)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String("Done")) { dismiss() }
                }
            }
            .onAppear {
                savedBundles = store.bundles()
                courier?.resetSendState()
            }
            .onChange(of: scope) { bundle = nil }
            .onChange(of: includesAudio) { bundle = nil }
            .onChange(of: photoItems) { _, items in Task { await load(items) } }
            .fileImporter(isPresented: $isImportingImages, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { importFiles(urls) }
            }
        }
        .perfScreen("debugBundle")
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    @ViewBuilder
    private var attachmentList: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                        AttachmentThumbnail(attachment: attachment) {
                            attachments.remove(at: index)
                        }
                    }
                }
            }
            .accessibilityLabel(String("\(attachments.count) attached images"))
        }
    }

    @ViewBuilder
    private var attachmentButtons: some View {
        Button(String("Add Photos"), systemImage: "photo.on.rectangle") { isPickingPhotos = true }
        Button(String("Add Image File…"), systemImage: "doc.badge.plus") { isImportingImages = true }
        #if os(macOS)
        Button(String("Paste Screenshot"), systemImage: "doc.on.clipboard", action: pasteImage)
            .help(String("Attach the image on the clipboard, for example from ⌃⇧⌘4"))
        #endif
    }

    @ViewBuilder
    private var sendStatus: some View {
        switch courier?.sendState ?? .idle {
        case .idle:
            EmptyView()
        case .sending(let sent, let total):
            ProgressView(value: Double(sent), total: Double(max(total, 1))) {
                Text(verbatim: "Sending to your Mac through iCloud")
            }
        case .sent:
            Label(String("Sent. Your Mac collects it the next time Still runs there."), systemImage: "checkmark.icloud")
                .foregroundStyle(.green)
        case .savedHere(let url):
            Label(String("Saved to \(url.deletingLastPathComponent().lastPathComponent)"), systemImage: "tray.and.arrow.down")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(String("Not sent: \(message). The bundle is saved here; share it instead."), systemImage: "exclamationmark.icloud")
                .foregroundStyle(.red)
        }
    }

    private var submitFooter: String {
        #if os(macOS)
        "Submit sends the report through your own iCloud to the Mac that collects bug reports. Saved bundles stay in Downloads › Still Debug Bundles (newest 10)."
        #else
        "Submit sends the report through your own iCloud to the Mac that collects bug reports. Saved bundles stay on this device (newest 10) until you share or delete them."
        #endif
    }

    private var scopes: [Scope] {
        Scope.allCases.filter { $0 != .given || givenRecordingID != nil }
    }

    private func label(_ scope: Scope) -> String {
        switch scope {
        case .given: "This recording"
        case .latest: "Latest recording"
        case .lastFive: "Last 5 recordings"
        case .all: "All \(library.recordingsInEveryProject.count) recordings"
        case .none: "Logs only"
        }
    }

    private var recordingIDs: [UUID] {
        let newest = library.recordingsInEveryProject.sorted { $0.createdAt > $1.createdAt }.map(\.id)
        switch scope {
        case .given: return givenRecordingID.map { [$0] } ?? []
        case .latest: return Array(newest.prefix(1))
        case .lastFive: return Array(newest.prefix(5))
        case .all: return newest
        case .none: return []
        }
    }

    private func mark() {
        isWritingNote = false
        let marker = ProblemMarker(reason: .tester, note: note, screen: Interactions.screen)
        let state = builder.state?.snapshot()
        if let markers {
            Task.detached(priority: .userInitiated) { markers.capture(marker, state: state) }
        }
        markedAt = marker.at
    }

    private func prepare(submitting: Bool) {
        isWritingNote = false
        problem = nil
        saved = nil
        step = "Starting"
        courier?.resetSendState()
        let request = DebugBundleRequest(recordingIDs: recordingIDs, includesAudio: includesAudio, note: note, attachments: attachments)
        Task {
            do {
                let zip = try await builder.build(request) { step = $0 }
                let kept = try store.save(zip)
                bundle = kept
                savedBundles = store.bundles()
                if submitting, let courier {
                    step = "Sending"
                    await courier.submit(kept)
                } else {
                    saved = "Saved \(kept.lastPathComponent)"
                }
            } catch {
                problem = error.localizedDescription
                DevLog.error("debugBundle.failed", error)
            }
            step = nil
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            attachments.append(BugReportAttachment(name: "attachment-\(attachments.count + 1).\(ext)", data: data))
        }
        photoItems = []
    }

    private func importFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            attachments.append(BugReportAttachment(name: "attachment-\(attachments.count + 1)-\(url.lastPathComponent)", data: data))
        }
    }

    #if os(macOS)
    private func pasteImage() {
        guard let image = NSImage(pasteboard: .general),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else {
            problem = "The clipboard holds no image."
            return
        }
        attachments.append(BugReportAttachment(name: "attachment-\(attachments.count + 1).png", data: png))
    }
    #endif
}

private struct AttachmentThumbnail: View {
    let attachment: BugReportAttachment
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            preview
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(String("Attached image \(attachment.name)"))
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String("Remove \(attachment.name)"))
            .padding(2)
        }
    }

    @ViewBuilder
    private var preview: some View {
        #if os(macOS)
        if let image = NSImage(data: attachment.data) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Image(systemName: "photo").resizable().scaledToFit().padding(16)
        }
        #else
        if let image = UIImage(data: attachment.data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Image(systemName: "photo").resizable().scaledToFit().padding(16)
        }
        #endif
    }
}

private struct SavedBundleRow: View {
    let bundle: SavedBundle
    let delete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(verbatim: bundle.name)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: "\(Int64(bundle.bytes).formatted(.byteCount(style: .file))) · \(bundle.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            ShareLink(item: bundle.url) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel(String("Share \(bundle.name)"))
            #if os(macOS)
            Button(String("Show in Finder"), systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([bundle.url])
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel(String("Show \(bundle.name) in Finder"))
            #endif
            Button(String("Delete"), systemImage: "trash", role: .destructive, action: delete)
                .labelStyle(.iconOnly)
                .accessibilityLabel(String("Delete \(bundle.name)"))
        }
        .buttonStyle(.borderless)
    }
}

private struct BugReportInboxSection: View {
    @Bindable var courier: BugReportCourier

    var body: some View {
        Section {
            Toggle(String("Collect bug reports on this Mac"), isOn: $courier.receives)
            if courier.receives {
                LabeledContent(String("Received"), value: String(courier.received.count))
                if let lastChecked = courier.lastChecked {
                    LabeledContent(String("Last checked"), value: lastChecked.formatted(date: .omitted, time: .shortened))
                }
                HStack {
                    Button(String("Check Now"), systemImage: "arrow.clockwise") {
                        Task { await courier.collect() }
                    }
                    #if os(macOS)
                    Button(String("Show in Finder"), systemImage: "folder") {
                        try? FileManager.default.createDirectory(at: courier.inboxDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(courier.inboxDirectory)
                    }
                    #endif
                }
                if let problem = courier.receiveProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text(verbatim: "Bug Reports from Your Devices")
        } footer: {
            Text(verbatim: "This Mac takes reports your iPhone, iPad and other Macs submit, saves them to Downloads › Still Bug Reports, and removes them from iCloud.")
        }
    }
}

struct DebugBundleButton: View {
    let diagnostics: Diagnostics
    let library: Library
    var recordingID: UUID?
    var title = "Report a Problem"

    var body: some View {
        if diagnostics.debugBundleBuilder(library: library) != nil {
            Button(title, systemImage: "ladybug") {
                Interactions.begin("debugBundle.open")
                diagnostics.requestProblemReport(from: .button, recordingID: recordingID)
            }
            .help(String("Send logs, timings, audio, screenshots and AI results to the developer"))
        }
    }
}

/// Presents the report sheet wherever it was asked for: a toolbar button,
/// the menu bar, the global shortcut, a shake, or the next launch after a
/// crash.
struct ProblemReportPresenter: ViewModifier {
    @Bindable var diagnostics: Diagnostics
    let library: Library

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if let problem = diagnostics.developer.previousLaunchProblem, diagnostics.developer.allowsDebugBundle {
                    PreviousLaunchBanner(message: problem) {
                        diagnostics.developer.dismissPreviousLaunchProblem()
                        diagnostics.requestProblemReport(from: .previousLaunch)
                    } dismiss: {
                        diagnostics.developer.dismissPreviousLaunchProblem()
                    }
                }
            }
            #if os(iOS)
            .sheet(item: $diagnostics.problemReport) { request in
                ProblemReportContent(diagnostics: diagnostics, library: library, request: request)
            }
            .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
                guard diagnostics.problemReport == nil else { return }
                diagnostics.requestProblemReport(from: .shake)
            }
            #endif
    }
}

struct ProblemReportContent: View {
    let diagnostics: Diagnostics
    let library: Library
    let request: ProblemReportRequest

    var body: some View {
        if let builder = diagnostics.debugBundleBuilder(library: library) {
            DebugBundleView(
                builder: builder,
                library: library,
                courier: diagnostics.bugReports,
                markers: diagnostics.developer.markers,
                recordingID: request.recordingID
            )
            .id(request.id)
        } else if diagnostics.developer.channel == .unknown {
            ContentUnavailableView {
                Label {
                    Text(verbatim: "Checking This Build")
                } icon: {
                    ProgressView()
                }
            } description: {
                Text(verbatim: "Still is asking the App Store whether this is a TestFlight build. Report a Problem opens here as soon as it answers.")
            } actions: {
                Button(String("Ask Again")) { Task { await diagnostics.developer.resolveAgainIfUnknown() } }
            }
            .task { await diagnostics.developer.resolveAgainIfUnknown() }
        } else {
            ContentUnavailableView {
                Label(String("Only in TestFlight Builds"), systemImage: "ladybug")
            } description: {
                Text(verbatim: "This build does not collect developer diagnostics.")
            }
        }
    }
}

#if os(macOS)
/// On a Mac the report has its own window, so the menu bar, the global
/// shortcut and Settings can all open it whichever window is in front.
struct ProblemReportWindow: View {
    let diagnostics: Diagnostics
    let library: Library

    var body: some View {
        ProblemReportContent(diagnostics: diagnostics, library: library, request: diagnostics.problemReport ?? ProblemReportRequest(source: .button))
            .onDisappear { diagnostics.problemReport = nil }
    }
}

/// Lives on the always-present menu bar label and opens the report window
/// whenever a report is asked for.
struct ProblemReportWindowOpener: ViewModifier {
    static let windowID = "problemReport"

    let diagnostics: Diagnostics
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: diagnostics.problemReport?.id) { _, id in
            guard id != nil else { return }
            NSApp.activate()
            openWindow(id: Self.windowID)
        }
    }
}
#endif

private struct PreviousLaunchBanner: View {
    let message: String
    let report: () -> Void
    let dismiss: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    notice
                    HStack { actions }
                }
            } else {
                HStack(spacing: 12) {
                    notice
                    Spacer()
                    actions
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .accessibilityElement(children: .contain)
    }

    private var notice: some View {
        Label {
            Text(verbatim: message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button(String("Report"), action: report)
            .buttonStyle(.borderedProminent)
            .fixedSize()
        Button(String("Dismiss"), systemImage: "xmark", action: dismiss)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .accessibilityLabel(String("Dismiss"))
    }
}

#if os(iOS)
extension Notification.Name {
    static let deviceDidShake = Notification.Name("StillDeviceDidShake")
}

extension UIWindow {
    override open func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}
#endif
