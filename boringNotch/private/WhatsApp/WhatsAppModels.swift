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
}

/// Connection lifecycle of the WhatsApp bridge.
enum WAConnectionState: Equatable {
    case disconnected
    case connecting
    case awaitingQR(String)
    case loggedIn
    case failed(String)
}
