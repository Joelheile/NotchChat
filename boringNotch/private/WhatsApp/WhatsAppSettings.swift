import Defaults
import SwiftUI

/// Settings pane for the WhatsApp notch panel.
struct WhatsAppSettings: View {
    @ObservedObject private var manager = WhatsAppManager.shared
    @Default(.showWhatsApp) private var showWhatsApp
    @Default(.whatsAppContactName) private var contactName
    @Default(.whatsAppContactJID) private var contactNumber

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showWhatsApp) {
                    Text("Show WhatsApp in the notch")
                }
                Text("Replaces the calendar in the right column while enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: Text("Cofounder")) {
                TextField("Name", text: $contactName)
                TextField("Phone number (with country code)", text: $contactNumber)
                Text("Digits only, e.g. 491701234567. Used to match the chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: Text("Connection")) {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(statusText)
                        .foregroundStyle(statusColor)
                }
                Button("Unlink device") {
                    manager.logout()
                }
                .disabled(!isLoggedIn)
            }

            Section(header: Text("Setup")) {
                Text("""
                The WhatsApp bridge runs as a small background process built \
                from whatsapp-sidecar/. Build it once with whatsapp-sidecar/build.sh, \
                then rebuild the app. Install ffmpeg (brew install ffmpeg) so voice \
                notes can be played.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .onChange(of: showWhatsApp) { _, enabled in
            if enabled { manager.start() }
        }
    }

    private var isLoggedIn: Bool {
        if case .loggedIn = manager.connection { return true }
        return false
    }

    private var statusText: String {
        switch manager.connection {
        case .disconnected: return "Not running"
        case .connecting: return "Connecting"
        case .awaitingQR: return "Waiting for QR scan"
        case .loggedIn: return "Linked"
        case .failed(let reason): return "Error: \(reason)"
        }
    }

    private var statusColor: Color {
        switch manager.connection {
        case .loggedIn: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}
