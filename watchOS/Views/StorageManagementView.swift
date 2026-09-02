import SwiftUI

struct StorageManagementView: View {
    @ObservedObject private var receiver = WatchFileReceiver.shared
    @State private var playlistSizes: [(Playlist, Double)] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // Overview card
                VStack(spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%.0f MB", receiver.usedMB))
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                            Text("used by YTWatch")
                                .font(.system(size: 10))
                                .foregroundStyle(Color(white: 0.4))
                        }
                        Spacer()
                        Image(systemName: "internaldrive.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color.ytRed.opacity(0.5))
                    }

                    // Storage bar
                    let total = receiver.totalDeviceStorageMB
                    let free = receiver.freeDeviceStorageMB
                    let musicPct = total > 0 ? receiver.usedMB / total : 0

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color(white: 0.15))
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.ytRed)
                                .frame(width: max(2, geo.size.width * musicPct))
                        }
                    }
                    .frame(height: 6)

                    HStack {
                        Text(String(format: "%.1f GB free", free / 1000))
                            .font(.system(size: 9))
                            .foregroundStyle(Color(white: 0.35))
                        Spacer()
                        Text(String(format: "%.1f GB total", total / 1000))
                            .font(.system(size: 9))
                            .foregroundStyle(Color(white: 0.35))
                    }
                }
                .padding(12)
                .background(Color(white: 0.07))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                // Track & playlist count
                HStack(spacing: 12) {
                    StatBadge(
                        value: "\(receiver.availablePlaylists.count)",
                        label: "Playlists"
                    )
                    StatBadge(
                        value: "\(receiver.availablePlaylists.reduce(0) { $0 + $1.tracks.count })",
                        label: "Tracks"
                    )
                }

                // Per-playlist breakdown
                if !playlistSizes.isEmpty {
                    HStack {
                        Text("BY PLAYLIST")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color(white: 0.35))
                        Spacer()
                    }
                    .padding(.top, 4)
                    .padding(.horizontal, 4)

                    ForEach(playlistSizes, id: \.0.id) { playlist, sizeMB in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text("\(playlist.tracks.count) tracks")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color(white: 0.35))
                            }
                            Spacer()
                            Text(String(format: "%.0f MB", sizeMB))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color(white: 0.4))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(white: 0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { computeSizes() }
    }

    private func computeSizes() {
        let playlists = receiver.availablePlaylists
        playlistSizes = playlists.map { ($0, receiver.storageMB(for: $0)) }
            .sorted { $0.1 > $1.1 }
    }
}

private struct StatBadge: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Color(white: 0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(white: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
