import SwiftUI
import WatchKit

struct NowPlayingScreen: View {
    @ObservedObject private var player = WatchPlayer.shared

    private var safeDuration: Double {
        player.duration.isFinite ? min(max(0, player.duration), 100_000_000) : 0
    }

    private var safeTime: Double {
        player.currentTime.isFinite ? min(max(0, player.currentTime), 100_000_000) : 0
    }

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)

            if let track = player.currentTrack {
                Text(track.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Nothing playing")
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: min(safeTime, safeDuration), total: max(safeDuration, 1))
                .tint(.red)
            HStack {
                Text(clock(safeTime))
                Spacer()
                Text(clock(safeDuration))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)

            HStack(spacing: 18) {
                Button { player.previous() } label: {
                    Image(systemName: "backward.end.fill")
                }
                .accessibilityLabel("Previous track")

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Button { player.next() } label: {
                    Image(systemName: "forward.end.fill")
                }
                .accessibilityLabel("Next track")
            }
            .buttonStyle(.plain)
            .font(.title3)
            .padding(.vertical, 8)

            NavigationLink(destination: WatchKit.NowPlayingView()) {
                Text("System controls")
                    .font(.caption2)
            }

            if let error = player.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func clock(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return "\(whole / 60):\(String(format: "%02d", whole % 60))"
    }
}
