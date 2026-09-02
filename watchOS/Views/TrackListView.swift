import SwiftUI
import UIKit
import ImageIO

// MARK: - Watch Thumbnail Cache

@MainActor
final class WatchThumbnailCache {
    static let shared = WatchThumbnailCache()
    private var cache: [String: UIImage] = [:]
    // Keep this modest — full-size YouTube thumbnails in memory are a big source of
    // memory pressure on the Watch. We downsample and cap the cache.
    private let maxEntries = 50

    func image(for videoId: String) -> UIImage? {
        if let cached = cache[videoId] { return cached }
        guard let url = WatchFileReceiver.shared.thumbnailURL(for: videoId),
              let img = Self.downsampledImage(at: url, maxPixel: 200) else { return nil }
        if cache.count >= maxEntries {
            // Evict roughly half when full
            let keys = Array(cache.keys.prefix(maxEntries / 2))
            for k in keys { cache.removeValue(forKey: k) }
        }
        cache[videoId] = img
        return img
    }

    func clear() { cache.removeAll() }

    /// Decode a downsampled thumbnail with ImageIO — never holds the full-size bitmap.
    private static func downsampledImage(at url: URL, maxPixel: CGFloat) -> UIImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct TrackListView: View {
    let playlist: Playlist
    @ObservedObject private var player = WatchPlayer.shared
    @State private var showNowPlaying = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 4) {
                    // Shuffle All
                    Button(action: {
                        guard !playlist.tracks.isEmpty else { return }
                        player.load(playlist: playlist, startAt: Int.random(in: 0..<playlist.tracks.count))
                        if !player.isShuffled { player.toggleShuffle() }
                        showNowPlaying = true
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "shuffle")
                                .font(.system(size: 10, weight: .bold))
                            Text("Shuffle All")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Color.ytRed)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.ytRed.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.ytRed.opacity(0.25), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)

                    ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { index, track in
                        Button(action: {
                            player.load(playlist: playlist, startAt: index)
                            showNowPlaying = true
                        }) {
                            WatchTrackRow(
                                track: track,
                                isActive: player.currentTrack?.id == track.id
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // Open now playing if something is playing from this playlist
                    if let current = player.currentTrack,
                       playlist.tracks.contains(where: { $0.id == current.id }) {
                        NavigationLink(destination: NowPlayingScreen()) {
                            HStack(spacing: 6) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.ytRed)
                                    .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                                Text("Now Playing")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.ytRed)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.ytRed.opacity(0.08))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)

                        // Up Next queue
                        let upcoming = player.upNextTracks
                        if !upcoming.isEmpty {
                            HStack {
                                Text("UP NEXT")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Color(white: 0.35))
                                Spacer()
                                Text("\(upcoming.count) tracks")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color(white: 0.25))
                            }
                            .padding(.horizontal, 4)
                            .padding(.top, 8)

                            ForEach(Array(upcoming.prefix(10).enumerated()), id: \.element.videoId) { _, track in
                                UpNextRow(
                                    track: track,
                                    onPlayNext: { player.playTrackNext(videoId: track.videoId) },
                                    onRemove: { player.removeFromQueue(videoId: track.videoId) }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showNowPlaying) {
            NowPlayingScreen()
        }
    }
}

private struct WatchTrackRow: View {
    let track: Track
    let isActive: Bool
    @ObservedObject private var player = WatchPlayer.shared

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .center) {
                if let img = WatchThumbnailCache.shared.image(for: track.videoId) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(white: 0.15))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 10, weight: .light))
                                .foregroundStyle(Color(white: 0.3))
                        )
                }

                if isActive {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.black.opacity(0.5))
                        .frame(width: 32, height: 32)
                    Image(systemName: "waveform")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.ytRed)
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 12, weight: isActive ? .bold : .medium))
                    .foregroundStyle(isActive ? Color.ytRed : .white)
                    .lineLimit(2)
                Text(track.artist)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: isActive ? 0.5 : 0.35))
                    .lineLimit(1)
            }

            Spacer()

            Text(track.durationFormatted)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color(white: 0.25))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isActive ? Color.ytRed.opacity(0.1) : Color(white: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isActive ? Color.ytRed.opacity(0.3) : Color.clear, lineWidth: 0.5)
        )
        .animation(.easeOut(duration: 0.2), value: isActive)
    }
}

private struct UpNextRow: View {
    let track: Track
    var onPlayNext: () -> Void
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let img = WatchThumbnailCache.shared.image(for: track.videoId) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(white: 0.12))
                    .frame(width: 24, height: 24)
            }

            Text(track.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(white: 0.5))
                .lineLimit(1)

            Spacer()

            Button(action: onPlayNext) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.ytRed)
            }
            .buttonStyle(.plain)

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(white: 0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(white: 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
