import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// Quick Look preview for a WhatsApp image. Tapping a bubble downloads the
/// media to a temp file and shows it in a floating window, closeable with Esc.
@MainActor
final class WAImagePreview: NSObject, NSWindowDelegate {
    static let shared = WAImagePreview()

    private var window: NSWindow?
    private var escMonitor: Any?
    private var tempFile: URL?
    private var interactionActive = false

    func show(message: WAMessage) {
        guard let remoteURL = WhatsAppManager.shared.mediaURL(for: message) else { return }
        Task {
            guard let fileURL = await download(remoteURL, contentType: message.mediaContentType)
            else { return }
            openWindow(fileURL: fileURL)
        }
    }

    private func download(_ url: URL, contentType: String?) async -> URL? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let ext = contentType
                .flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? "jpg"
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("wa-preview-\(UUID().uuidString)")
                .appendingPathExtension(ext)
            try data.write(to: dest)
            return dest
        } catch {
            NSLog("WAImagePreview download failed: \(error)")
            return nil
        }
    }

    private func openWindow(fileURL: URL) {
        close()
        tempFile = fileURL

        let hosting = NSHostingController(rootView: QuickLookView(url: fileURL))
        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.isMovableByWindowBackground = true
        win.backgroundColor = .black
        win.level = .floating
        win.delegate = self
        win.setContentSize(NSSize(width: 760, height: 620))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win

        // Keep the notch chat panel open while the preview window has focus.
        SharingStateManager.shared.beginInteraction()
        interactionActive = true

        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            self?.close()
            return nil
        }
    }

    func close() {
        if interactionActive {
            SharingStateManager.shared.endInteraction()
            interactionActive = false
        }
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
        if let tempFile { try? FileManager.default.removeItem(at: tempFile) }
        tempFile = nil
    }

    func windowWillClose(_ notification: Notification) {
        close()
    }
}

/// Hosts an `QLPreviewView` so the image renders with the native Quick Look UI.
private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = QLItem(url)
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if (nsView.previewItem as? QLItem)?.previewItemURL != url {
            nsView.previewItem = QLItem(url)
        }
    }
}

private final class QLItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    init(_ url: URL) { previewItemURL = url }
}
