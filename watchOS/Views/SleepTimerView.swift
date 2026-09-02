import SwiftUI
import WatchKit

struct SleepTimerView: View {
    @ObservedObject private var player = WatchPlayer.shared

    private let presets: [(String, Int)] = [
        ("15 min", 15),
        ("30 min", 30),
        ("45 min", 45),
        ("60 min", 60),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if player.sleepTimerRemaining != nil {
                    // Active timer
                    VStack(spacing: 4) {
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.purple)

                        if player.isSleepTimerEndOfTrack {
                            Text("End of track")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                        } else if let remaining = player.sleepTimerRemaining {
                            Text(formatTimer(remaining))
                                .font(.system(size: 22, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                        }

                        Text("Music will pause")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(white: 0.4))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.purple.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button {
                        player.cancelSleepTimer()
                    } label: {
                        HStack {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12, weight: .medium))
                            Text("Cancel Timer")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Color.ytRed)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.ytRed.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else {
                    // Timer selection
                    ForEach(presets, id: \.1) { label, minutes in
                        Button {
                            player.startSleepTimer(minutes: minutes)
                        } label: {
                            HStack {
                                Image(systemName: "moon.zzz")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.purple)
                                Text(label)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color(white: 0.09))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        player.startSleepTimerEndOfTrack()
                    } label: {
                        HStack {
                            Image(systemName: "forward.end")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.purple)
                            Text("End of track")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(white: 0.09))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle("Sleep Timer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formatTimer(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
