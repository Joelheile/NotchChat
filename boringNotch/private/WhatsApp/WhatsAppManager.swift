import Combine
import Defaults
import Foundation

/// Owns the connection to the WhatsApp sidecar: launches it, consumes its
/// Server-Sent-Events stream, keeps per-chat message history, and sends
/// outgoing text and images to whichever contact tab is selected.
@MainActor
final class WhatsAppManager: ObservableObject {
    static let shared = WhatsAppManager()

    @Published private(set) var connection: WAConnectionState = .disconnected
    @Published private(set) var contacts: [WAContact] = []
    @Published private(set) var selectedJID: String = ""
    @Published private(set) var messagesByChat: [String: [WAMessage]] = [:]
    @Published private(set) var unreadByChat: [String: Bool] = [:]
    @Published private(set) var latestPreview: WAMessage?

    private var streamTask: Task<Void, Never>?
    private var started = false

    private init() {
        migrateLegacyContact()
        contacts = Defaults[.whatsAppContacts]
        let last = Defaults[.whatsAppLastContact]
        selectedJID = contacts.contains { $0.jid == last } ? last : (contacts.first?.jid ?? "")
    }

    // MARK: Configuration

    var isConfigured: Bool { !contacts.isEmpty }

    var selectedContact: WAContact? { contacts.first { $0.jid == selectedJID } }

    /// Messages for the currently selected contact tab, oldest first.
    var messages: [WAMessage] { messagesByChat[selectedJID] ?? [] }

    /// True when any contact tab has an unread message.
    var hasUnread: Bool { unreadByChat.values.contains(true) }

    private var contactJIDs: Set<String> { Set(contacts.map(\.jid)) }

    func name(for jid: String) -> String {
        contacts.first { $0.jid == jid }?.displayName ?? "WhatsApp"
    }

    /// One-time migration of the old single-contact settings into the list.
    private func migrateLegacyContact() {
        guard Defaults[.whatsAppContacts].isEmpty else { return }
        let raw = Defaults[.whatsAppContactJID].trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        Defaults[.whatsAppContacts] = [WAContact(name: Defaults[.whatsAppContactName], number: raw)]
    }

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

    /// Marks the selected chat read and drops the closed-notch preview.
    func markRead() {
        unreadByChat[selectedJID] = false
        latestPreview = nil
    }

    /// Switches the active contact tab and remembers it for next launch.
    func select(_ jid: String) {
        guard jid != selectedJID else { return }
        selectedJID = jid
        Defaults[.whatsAppLastContact] = jid
        unreadByChat[jid] = false
    }

    /// Re-reads the contact list from settings and tells the sidecar which
    /// chats to keep. Called when the settings list changes.
    func reloadContacts() {
        contacts = Defaults[.whatsAppContacts]
        if !contacts.contains(where: { $0.jid == selectedJID }) {
            selectedJID = contacts.first?.jid ?? ""
        }
        for jid in messagesByChat.keys where !contactJIDs.contains(jid) {
            messagesByChat[jid] = nil
            unreadByChat[jid] = nil
        }
        pushContacts()
    }

    // MARK: Sending

    /// Builds a request to the sidecar carrying the shared secret. Every call
    /// must use this so the sidecar accepts it.
    private func authedRequest(path: String) -> URLRequest {
        var request = URLRequest(url: WhatsAppSidecar.shared.baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(WhatsAppSidecar.shared.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Sends text to the selected contact. Returns false on failure so the
    /// caller can keep the user's draft instead of losing it.
    func send(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !selectedJID.isEmpty else { return false }
        var request = authedRequest(path: "send")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["to": selectedJID, "text": trimmed])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            NSLog("[WhatsApp] send failed: \(error)")
            return false
        }
    }

    /// Uploads a photo to the selected contact via the sidecar.
    func sendImage(data: Data, filename: String, contentType: String, caption: String = "") {
        guard !data.isEmpty, !selectedJID.isEmpty else { return }
        let recipient = selectedJID
        Task {
            var request = authedRequest(path: "sendImage")
            request.httpMethod = "POST"
            let boundary = "Boundary-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.multipartBody(
                boundary: boundary,
                fields: ["to": recipient, "caption": caption],
                fileField: "image",
                filename: filename,
                contentType: contentType,
                fileData: data
            )
            do {
                _ = try await URLSession.shared.data(for: request)
            } catch {
                NSLog("[WhatsApp] image send failed: \(error)")
            }
        }
    }

    /// Encodes text fields and one file part into a multipart/form-data body.
    private static func multipartBody(
        boundary: String,
        fields: [String: String],
        fileField: String,
        filename: String,
        contentType: String,
        fileData: Data
    ) -> Data {
        var body = Data()
        let newline = "\r\n"
        func append(_ string: String) { body.append(Data(string.utf8)) }

        for (name, value) in fields {
            append("--\(boundary)\(newline)")
            append("Content-Disposition: form-data; name=\"\(name)\"\(newline)\(newline)")
            append("\(value)\(newline)")
        }
        append("--\(boundary)\(newline)")
        append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\(newline)")
        append("Content-Type: \(contentType)\(newline)\(newline)")
        body.append(fileData)
        append(newline)
        append("--\(boundary)--\(newline)")
        return body
    }

    func logout() {
        Task {
            var request = authedRequest(path: "logout")
            request.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: request)
        }
        messagesByChat = [:]
        unreadByChat = [:]
        latestPreview = nil
        connection = .connecting
    }

    /// Tells the sidecar which chat JIDs to keep, scoping history import.
    private func pushContacts() {
        let jids = contacts.map(\.jid).filter { !$0.isEmpty }
        Task {
            var request = authedRequest(path: "contacts")
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["jids": jids])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    // MARK: Media URLs

    func mediaURL(for message: WAMessage) -> URL? {
        guard let id = message.mediaID else { return nil }
        return sidecarURL(path: "media", queryItems: [URLQueryItem(name: "id", value: id)])
    }

    /// URL of a contact's WhatsApp profile picture, or nil if not configurable.
    func avatarURL(for jid: String) -> URL? {
        guard !jid.isEmpty else { return nil }
        return sidecarURL(path: "avatar", queryItems: [URLQueryItem(name: "jid", value: jid)])
    }

    /// Builds a sidecar URL with the auth token as a query parameter, for
    /// AsyncImage/AVPlayer which cannot attach an Authorization header.
    private func sidecarURL(path: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents(
            url: WhatsAppSidecar.shared.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems + [
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
        // Resend the contact list whenever the stream (re)connects so a
        // freshly started sidecar always knows which chats to keep.
        pushContacts()
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
            messagesByChat = [:]
            unreadByChat = [:]
            latestPreview = nil
            connection = .connecting
        case "message":
            if let data = object["data"],
               let encoded = try? JSONSerialization.data(withJSONObject: data),
               let message = try? JSONDecoder().decode(WAMessage.self, from: encoded) {
                ingest(message)
            }
        case "messages":
            if let data = object["data"],
               let encoded = try? JSONSerialization.data(withJSONObject: data),
               let batch = try? JSONDecoder().decode([WAMessage].self, from: encoded) {
                ingestBatch(batch)
            }
        default:
            break
        }
    }

    /// Replaces stored history with a full snapshot in one update so the UI
    /// renders it in a single pass.
    private func ingestBatch(_ batch: [WAMessage]) {
        var grouped: [String: [WAMessage]] = [:]
        for message in batch where contactJIDs.contains(message.chatJID) {
            grouped[message.chatJID, default: []].append(message)
        }
        for jid in grouped.keys {
            grouped[jid]?.sort { $0.timestamp < $1.timestamp }
        }
        messagesByChat = grouped
        if case .connecting = connection { connection = .loggedIn }
        latestPreview = batch
            .filter { !$0.fromMe }
            .max { $0.timestamp < $1.timestamp }
    }

    private func ingest(_ message: WAMessage) {
        let jid = message.chatJID
        // Keep only messages for a configured contact tab.
        guard contactJIDs.contains(jid) else { return }
        if case .connecting = connection { connection = .loggedIn }

        var list = messagesByChat[jid] ?? []
        if let index = list.firstIndex(where: { $0.id == message.id }) {
            list[index] = message
        } else {
            list.append(message)
            list.sort { $0.timestamp < $1.timestamp }
            if !message.fromMe {
                if jid != selectedJID { unreadByChat[jid] = true }
                latestPreview = message
            }
        }
        messagesByChat[jid] = list
    }
}
