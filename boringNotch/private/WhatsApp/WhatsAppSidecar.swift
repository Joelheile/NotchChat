import Defaults
import Foundation
import Security

/// Launches and supervises the Go WhatsApp bridge process. The binary ships
/// inside the app bundle; it is copied to Application Support so it is writable
/// and reliably executable, then run as a child process.
final class WhatsAppSidecar {
    static let shared = WhatsAppSidecar()

    private var process: Process?
    private let port: Int

    /// Shared secret passed to the sidecar on launch and required on every
    /// request. Regenerated each app launch; never persisted.
    let token: String = Self.makeToken()

    private init() {
        port = Defaults[.whatsAppSidecarPort]
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    /// Application Support directory for the bridge (session store + media).
    static var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("boringNotch/whatsapp", isDirectory: true)
    }

    func startIfNeeded() {
        guard process == nil else { return }
        guard let executable = preparedExecutable() else {
            NSLog("[WhatsApp] sidecar binary not found in bundle")
            return
        }
        let dataDir = Self.dataDirectory
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let task = Process()
        task.executableURL = executable
        task.arguments = ["--port", "\(port)", "--data", dataDir.path, "--token", token]
        task.terminationHandler = { [weak self] _ in
            self?.process = nil
        }
        do {
            try task.run()
            process = task
            NSLog("[WhatsApp] sidecar started on port \(port)")
        } catch {
            NSLog("[WhatsApp] failed to launch sidecar: \(error)")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    /// Copies the bundled binary into Application Support and marks it
    /// executable, returning the runnable URL.
    private func preparedExecutable() -> URL? {
        guard let bundled = Bundle.main.url(forResource: "whatsapp-sidecar", withExtension: nil) else {
            return nil
        }
        let dir = Self.dataDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("whatsapp-sidecar")

        let fm = FileManager.default
        let needsCopy: Bool = {
            guard let bundledDate = (try? bundled.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  let destDate = (try? dest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return true }
            return bundledDate > destDate
        }()
        if needsCopy || !fm.fileExists(atPath: dest.path) {
            try? fm.removeItem(at: dest)
            do {
                try fm.copyItem(at: bundled, to: dest)
            } catch {
                NSLog("[WhatsApp] failed to stage sidecar: \(error)")
                return nil
            }
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        return dest
    }
}
