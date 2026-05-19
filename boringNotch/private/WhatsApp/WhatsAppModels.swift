import Defaults
import Foundation

/// One chat message. JSON keys must stay in sync with the `Message` struct in
/// the Go sidecar (whatsapp-sidecar/main.go).
struct WAMessage: Identifiable, Codable, Equatable {
    let id: String
    let chatJID: String
    var senderJID: String = ""
    let fromMe: Bool
    let timestamp: Int
    var text: String = ""
    var type: String = "text" // text | audio | image | other
    var mediaID: String?
    var mediaContentType: String?
    var duration: Int = 0
    var pushName: String = ""

    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
    var isAudio: Bool { type == "audio" }

    /// True only when the image has been downloaded and is fetchable.
    var hasImage: Bool { type == "image" && mediaID != nil }
}

/// A WhatsApp chat the notch panel shows as a tab. Entered manually in
/// settings; `number` is a raw phone number (digits, with country code).
struct WAContact: Codable, Hashable, Identifiable, Defaults.Serializable {
    var name: String
    var number: String

    var id: String { jid }

    /// Phone number normalised to a WhatsApp JID.
    var jid: String {
        if number.contains("@") { return number }
        let digits = number.filter(\.isNumber)
        return digits.isEmpty ? "" : "\(digits)@s.whatsapp.net"
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? number : trimmed
    }

    /// Up to two uppercase letters for the avatar fallback.
    var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}

/// Connection lifecycle of the WhatsApp bridge.
enum WAConnectionState: Equatable {
    case disconnected
    case connecting
    case awaitingQR(String)
    case loggedIn
    case failed(String)
}
