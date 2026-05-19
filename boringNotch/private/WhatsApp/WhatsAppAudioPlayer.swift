import AVFoundation
import Foundation

/// Plays WhatsApp voice notes. The sidecar serves AAC/m4a (transcoded from
/// Opus when ffmpeg is available); `AVAudioPlayer` decodes that directly.
@MainActor
final class WAAudioPlayer: NSObject, ObservableObject {
    static let shared = WAAudioPlayer()

    @Published private(set) var playingID: String?
    @Published private(set) var progress: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ message: WAMessage) {
        if playingID == message.id {
            stop()
            return
        }
        guard let url = WhatsAppManager.shared.mediaURL(for: message) else { return }
        Task { await load(message: message, from: url) }
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        playingID = nil
        progress = 0
    }

    private func load(message: WAMessage, from url: URL) async {
        stop()
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            self.player = player
            playingID = message.id
            startTimer()
        } catch {
            NSLog("[WhatsApp] audio playback failed: \(error)")
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player, player.duration > 0 else { return }
                self.progress = player.currentTime / player.duration
            }
        }
    }
}

extension WAAudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
