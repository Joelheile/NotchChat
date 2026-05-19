import Combine
import Defaults
import Foundation

/// Owns the connection to the WhatsApp sidecar: launches it, consumes its
/// Server-Sent-Events stream, exposes messages for the configured chat, and
/// sends outgoing text.
@MainActor
final class WhatsAppManager: ObservableObject {
    static let shared = WhatsAppManager()

    @Published private(set) var connection: WAConnectionState = .disconnected
    @Published private(set) var messages: [WAMessage] = []
    @Published private(set) var hasUnread = false
    @Published private(set) var latestPreview: WAMessage?

    private var streamTask: Task<Void, Never>?
    private var started = false

    private init() {}

    // MARK: Configuration

    /// The cofounder's number, normalised to a WhatsApp JID. Accepts a raw
    /// phone number (digits only) or a full `...@s.whatsapp.net` JID.
    var contactJID: String {
        let raw = Defaults[.whatsAppContactJID].trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return "" }
        if raw.contains("@") { return raw }
        let digits = raw.filter(\.isNumber)
        return digits.isEmpty ? "" : "\(digits)@s.whatsapp.net"
    }

    var contactName: String {
        let name = Defaults[.whatsAppContactName].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Cofounder" : name
    }

    var isConfigured: Bool { !contactJID.isEmpty }

    // MARK: Lifecycle

    func startIfEnabled() {
        guard Defaults[.showWhatsApp] else { return }
        start()
    }

    func start() {
        guard !started else { return }
        started = true
        WhatsAppSidecar.shared.startIfNeeded()
        connection = .connecting
        listen()
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        started = false
    }

    func markRead() {
        hasUnread = false
        latestPreview = nil
    }

    // MARK: Sending

    /// Builds a request to the sidecar carrying the shared secret. Every call
    /// must use this so the sidecar accepts it.
    private func authedRequest(path: String) -> URLRequest {
        var request = URLRequest(url: WhatsAppSidecar.shared.baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(WhatsAppSidecar.shared.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isConfigured else { return }
        let recipient = contactJID
        Task {
            var request = authedRequest(path: "send")
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["to": recipient, "text": trimmed])
            do {
                _ = try await URLSession.shared.data(for: request)
            } catch {
                NSLog("[WhatsApp] send failed: \(error)")
            }
        }
    }

    func logout() {
        Task {
            var request = authedRequest(path: "logout")
            request.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: request)
        }
        messages = []
        connection = .connecting
    }

    func mediaURL(for message: WAMessage) -> URL? {
        guard let id = message.mediaID else { return nil }
        var components = URLComponents(
            url: WhatsAppSidecar.shared.baseURL.appendingPathComponent("media"),
            resolvingAgainstBaseURL: false
        )
        // AVPlayer/AsyncImage load this URL directly and cannot attach an
        // Authorization header, so the token rides as a query parameter.
        components?.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "token", value: WhatsAppSidecar.shared.token),
        ]
        return components?.url
    }

    // MARK: SSE stream

    private func listen() {
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await self?.consumeStream()
                } catch {
                    if Task.isCancelled { break }
                    NSLog("[WhatsApp] stream dropped: \(error)")
                }
                if Task.isCancelled { break }
                self?.connection = .connecting
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func consumeStream() async throws {
        let request = authedRequest(path: "events")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        for try await line in bytes.lines {
            if line.hasPrefix("data: ") {
                handleEvent(String(line.dropFirst(6)))
            }
        }
    }

    /// Decodes one SSE frame. The `data` field is heterogeneous, so it is
    /// inspected dynamically before being routed.
    private func handleEvent(_ json: String) {
        guard let raw = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let type = object["type"] as? String
        else { return }

        switch type {
        case "qr":
            if let code = object["data"] as? String {
                connection = .awaitingQR(code)
            }
        case "status":
            if let payload = object["data"] as? [String: Any] {
                let loggedIn = payload["loggedIn"] as? Bool ?? false
                if loggedIn {
                    connection = .loggedIn
                } else if case .loggedIn = connection {
                    connection = .connecting
                }
            }
        case "loggedout":
            messages = []
            connection = .connecting
        case "message":
            if let data = object["data"],
               let encoded = try? JSONSerialization.data(withJSONObject: data),
               let message = try? JSONDecoder().decode(WAMessage.self, from: encoded) {
                ingest(message)
            }
        default:
            break
        }
    }

    private func ingest(_ message: WAMessage) {
        // Keep only the configured chat. When unconfigured, show nothing.
        guard isConfigured, message.chatJID == contactJID else { return }
        if case .connecting = connection { connection = .loggedIn }

        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
            return
        }
        messages.append(message)
        messages.sort { $0.timestamp < $1.timestamp }
        if !message.fromMe {
            hasUnread = true
            latestPreview = message
        }
    }
}
