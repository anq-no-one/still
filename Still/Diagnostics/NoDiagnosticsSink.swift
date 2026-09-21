import Foundation

/// Until a diagnostics endpoint is provisioned with the signed build, an
/// enabled report has nowhere to go and is dropped. Nothing leaves the device
/// either way.
struct NoDiagnosticsSink: DiagnosticsSink {
    func send(_ report: DiagnosticReport) async {}
}
