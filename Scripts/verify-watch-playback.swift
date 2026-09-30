// Native regression check on macOS, using a downloaded file that AVAsset misreads.
// swiftc -swift-version 6 -parse-as-library Scripts/verify-watch-playback.swift -o /tmp/verify-watch-playback
// /tmp/verify-watch-playback /path/to/affected.m4a
import AppKit
import AVFoundation
import MediaPlayer

@main
@MainActor
struct VerifyWatchPlayback {
    private static var ended = false

    static func main() async throws {
        precondition(CommandLine.arguments.count == 2, "Pass an audio file path")

        // MediaPlayer requests artwork from a background queue. This closure must
        // remain Sendable even though it is constructed on the main actor.
        nonisolated(unsafe) let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 1, height: 1)) {
            @Sendable size in NSImage(size: size)
        }
        await Task.detached {
            precondition(artwork.image(at: CGSize(width: 1, height: 1)) != nil)
        }.value

        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let audio = try AVAudioFile(forReading: url)
        let seconds = Double(audio.length) / audio.processingFormat.sampleRate
        precondition(seconds.isFinite && seconds > 0)
        let asset = AVURLAsset(url: url)
        let container = try await asset.load(.duration).seconds
        let item = AVPlayerItem(asset: asset)
        item.forwardPlaybackEndTime = CMTime(seconds: seconds, preferredTimescale: 44_100)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { @Sendable _ in
            Task { @MainActor in ended = true }
        }
        defer {
            player.pause()
            NotificationCenter.default.removeObserver(observer)
        }

        let readyDeadline = Date().addingTimeInterval(10)
        while item.status == .unknown && Date() < readyDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(item.status == .readyToPlay, "Audio item did not become ready")
        let sought = await player.seek(
            to: CMTime(seconds: max(0, seconds - 1), preferredTimescale: 44_100),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
        precondition(sought)
        player.play()
        let endDeadline = Date().addingTimeInterval(5)
        while !ended && Date() < endDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(ended, "No end notification at the actual audio endpoint")
        precondition(player.currentTime().seconds <= seconds + 0.1)
        print("PASS: background artwork callback; end notification at \(seconds)s (container \(container)s)")
    }
}
