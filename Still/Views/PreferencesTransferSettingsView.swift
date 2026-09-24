import SwiftUI

struct PreferencesTransferSettingsView: View {
    let exporter: PreferencesExporter
    let importer: PreferencesImporter

    var body: some View {
        Form {
            PreferencesTransferSection(exporter: exporter, importer: importer)
        }
        .formStyle(.grouped)
        .settingsPaneTitle("Transfer Settings")
    }
}
