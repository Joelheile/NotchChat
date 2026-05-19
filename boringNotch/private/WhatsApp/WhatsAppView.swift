import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers

/// Right-column notch panel: a minimal WhatsApp chat with the configured
/// cofounder. Handles QR login, the message list, and sending text.
struct WhatsAppView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var manager = WhatsAppManager.shared
    @State private var draft = ""
    @State private var pendingImage: NSImage?
    @State private var keyMonitor: Any?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            switch manager.connection {
            case _ where !manager.isConfigured:
                placeholder(
                    icon: "person.crop.circle.badge.questionmark",
                    title: "No contact set",
                    detail: "Add your cofounder's number in Settings > WhatsApp."
                )
            case .loggedIn:
                chat
            case .awaitingQR(let code) where !code.isEmpty:
                qrLogin(code: code)
            case .failed(let reason):
                placeholder(icon: "exclamationmark.triangle", title: "WhatsApp error", detail: reason)
            default:
                placeholder(icon: "ellipsis.circle", title: "Connecting", detail: "Starting the WhatsApp bridge.")
            }
        }
        .foregroundStyle(.white)
        .onAppear {
            manager.start()
            manager.markRead()
            // Focus the field on open so the user can type without clicking it.
            DispatchQueue.main.async { inputFocused = true }
            installKeyMonitor()
        }
        .onDisappear {
            WAAudioPlayer.shared.stop()
            SharingStateManager.shared.preventNotchClose = false
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        // Keep the notch open while there is unsent text or a pending image.
        .onChange(of: draft) { _, _ in updateNotchHold() }
        .onChange(of: pendingImage != nil) { _, _ in updateNotchHold() }
    }

    private func updateNotchHold() {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        SharingStateManager.shared.preventNotchClose = hasText || pendingImage != nil
    }

    /// Local key monitor: handles Esc (collapse the notch) and Cmd+V of an
    /// image. A monitor is used instead of onKeyPress/onPasteCommand so both
    /// fire reliably even while the text field has focus.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                // Cancel a pending image first; otherwise collapse the notch.
                if pendingImage != nil {
                    pendingImage = nil
                } else {
                    inputFocused = false
                    vm.close()
                }
                return nil
            }
            // Cmd+V: stage a pasteboard image for confirmation. Text paste
            // (no image on the pasteboard) falls through to the text field.
            if event.keyCode == 9, event.modifierFlags.contains(.command),
               let image = NSImage(pasteboard: .general) {
                pendingImage = image
                return nil
            }
            return event
        }
    }

    // MARK: Chat

    private var chat: some View {
        VStack(spacing: 4) {
            messageList

            if let pendingImage {
                imageConfirmBar(pendingImage)
            }

            HStack(spacing: 5) {
                contactMenu

                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .lineLimit(1...5)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Color.white.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .focused($inputFocused)
                    // Enter sends; Shift+Enter inserts a newline. With a
                    // pending pasted image, Enter confirms and sends it.
                    .onKeyPress(keys: [.return]) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        if pendingImage != nil { sendPendingImage() } else { sendDraft() }
                        return .handled
                    }

                Button(action: pickImage) {
                    Image(systemName: "photo")
                        .font(.system(size: 14))
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Confirmation bar shown after a Cmd+V image paste, before it is sent.
    private func imageConfirmBar(_ image: NSImage) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text("Send image?")
                .font(.caption)

            Spacer(minLength: 0)

            Button { pendingImage = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.gray)
            }
            .buttonStyle(.plain)

            Button(action: sendPendingImage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Contact selector

    /// The contact's avatar in the input row. Doubles as a chat picker menu
    /// when more than one contact is configured.
    @ViewBuilder private var contactMenu: some View {
        let current = manager.contacts.first { $0.jid == manager.selectedJID }
        if manager.contacts.count > 1 {
            Menu {
                ForEach(manager.contacts) { contact in
                    Button {
                        manager.select(contact.jid)
                        manager.markRead()
                    } label: {
                        if contact.jid == manager.selectedJID {
                            Label(contact.name, systemImage: "checkmark")
                        } else if manager.unreadByChat[contact.jid] == true {
                            Label(contact.name, systemImage: "circle.fill")
                        } else {
                            Text(contact.name)
                        }
                    }
                }
            } label: {
                contactAvatar(current)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        } else if let current {
            contactAvatar(current)
        }
    }

    private func contactAvatar(_ contact: WAContact?) -> some View {
        AsyncImage(url: contact.flatMap { WhatsAppManager.shared.avatarURL(for: $0.jid) }) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Color.gray.opacity(0.35)
                    Image(systemName: "person.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(Circle())
    }

    // Cap rendered rows: a non-lazy VStack of the full history made the
    // open/close resize animation lag. The newest window is enough for a
    // glance; scroll up still works within it.
    private var displayedMessages: [WAMessage] {
        Array(manager.messages.suffix(80))
    }

    /// Inverted list: the scroll view and every row are flipped vertically and
    /// the messages iterate newest-first. The content's natural start is then
    /// the newest message, so the panel always opens pinned to the bottom with
    /// no scroll-position juggling. Scrolling up reveals older messages.
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    if displayedMessages.isEmpty {
                        Text("No messages yet")
                            .font(.caption2)
                            .foregroundStyle(.gray)
                            .padding(.top, 16)
                            .scaleEffect(x: 1, y: -1, anchor: .center)
                    }
                    ForEach(displayedMessages.reversed()) { message in
                        WAMessageRow(message: message)
                            .scaleEffect(x: 1, y: -1, anchor: .center)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .scaleEffect(x: 1, y: -1, anchor: .center)
            // After sending, jump back to the newest message even if the user
            // had scrolled up. Incoming messages keep their position.
            .onChange(of: manager.messages.count) {
                guard manager.messages.last?.fromMe == true,
                      let newest = displayedMessages.last else { return }
                withAnimation { proxy.scrollTo(newest.id, anchor: .center) }
            }
            // Reopening the notch always lands on the newest message.
            .onAppear {
                guard let newest = displayedMessages.last else { return }
                proxy.scrollTo(newest.id, anchor: .center)
            }
        }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task {
            // Restore the draft if the sidecar could not send it.
            let sent = await manager.send(text)
            if !sent { draft = text }
        }
    }

    /// Opens a file picker and sends the chosen image, using the current draft
    /// text as its caption.
    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let data = try? Data(contentsOf: url)
        else { return }

        let contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
        manager.sendImage(
            data: data,
            filename: url.lastPathComponent,
            contentType: contentType,
            caption: draft.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        draft = ""
    }

    /// Sends the image staged by a Cmd+V paste, using the draft as caption.
    private func sendPendingImage() {
        guard let image = pendingImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { pendingImage = nil; return }

        manager.sendImage(
            data: png,
            filename: "pasted.png",
            contentType: "image/png",
            caption: draft.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        draft = ""
        pendingImage = nil
    }

    // MARK: QR login

    private func qrLogin(code: String) -> some View {
        VStack(spacing: 6) {
            if let image = Self.qrImage(from: code) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Text("Scan in WhatsApp")
                .font(.caption.weight(.semibold))
            Text("Settings > Linked Devices > Link a Device")
                .font(.system(size: 9))
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.gray)
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 6)
    }

    /// Renders a QR payload string into a crisp image.
    static func qrImage(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// A single chat bubble: text or a playable voice note.
private struct WAMessageRow: View {
    let message: WAMessage
    @ObservedObject private var audio = WAAudioPlayer.shared

    var body: some View {
        HStack {
            if message.fromMe { Spacer(minLength: 24) }
            bubble
            if !message.fromMe { Spacer(minLength: 24) }
        }
    }

    @ViewBuilder
    private var bubble: some View {
        if message.hasImage {
            imageBubble
        } else {
            Group {
                if message.isAudio {
                    audioBubble
                } else {
                    Text(message.text.isEmpty ? imagePlaceholder : message.text)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                message.fromMe ? Color.green.opacity(0.45) : Color.white.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
    }

    private var imageBubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            AsyncImage(url: WhatsAppManager.shared.mediaURL(for: message)) { phase in
                switch phase {
                case .success(let image):
                    // scaledToFit shows the whole image; scaledToFill would
                    // centre-crop and can hide most of a tall screenshot.
                    image.resizable().scaledToFit()
                case .failure:
                    imageTile(icon: "exclamationmark.triangle")
                default:
                    imageTile(icon: "photo")
                }
            }
            // Fixed thumbnail box: keeps row height deterministic so the list
            // can anchor to the bottom before images finish loading.
            .frame(width: 190, height: 150)
            .background(Color.black.opacity(0.25))
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { WAImagePreview.shared.show(message: message) }

            if !message.text.isEmpty {
                Text(message.text)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
        }
        .frame(width: 190)
        .background(message.fromMe ? Color.green.opacity(0.45) : Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func imageTile(icon: String) -> some View {
        ZStack {
            Color.white.opacity(0.08)
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.gray)
        }
    }

    private var imagePlaceholder: String {
        message.type == "image" ? "Photo" : "Unsupported message"
    }

    private var audioBubble: some View {
        HStack(spacing: 6) {
            Button {
                audio.toggle(message)
            } label: {
                Image(systemName: audio.playingID == message.id ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)

            ProgressView(value: audio.playingID == message.id ? audio.progress : 0)
                .progressViewStyle(.linear)
                .frame(width: 52)
                .tint(.white)

            Text(durationLabel)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var durationLabel: String {
        let seconds = message.duration
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
