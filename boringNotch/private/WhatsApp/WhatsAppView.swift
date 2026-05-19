import CoreImage.CIFilterBuiltins
import SwiftUI

/// Right-column notch panel: a minimal WhatsApp chat with the configured
/// cofounder. Handles QR login, the message list, and sending text.
struct WhatsAppView: View {
    @ObservedObject private var manager = WhatsAppManager.shared
    @State private var draft = ""

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
        }
        .onDisappear { WAAudioPlayer.shared.stop() }
    }

    // MARK: Chat

    private var chat: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                Text(manager.contactName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
            }

            messageList

            HStack(spacing: 5) {
                TextField("Message", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.1), in: Capsule())
                    .onSubmit(sendDraft)

                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(draft.isEmpty ? .gray : .green)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    if manager.messages.isEmpty {
                        Text("No messages yet")
                            .font(.caption2)
                            .foregroundStyle(.gray)
                            .padding(.top, 16)
                    }
                    ForEach(manager.messages) { message in
                        WAMessageRow(message: message).id(message.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: manager.messages.count) {
                if let last = manager.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onAppear {
                if let last = manager.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        manager.send(text)
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
