import SwiftUI

struct ArtistView: View {
    let channelId: String
    let artistName: String

    @State private var artist: YTMusicClient.ArtistPage?
    @State private var isLoading = true
    @State private var appeared = false
    @State private var radioTrack: Track?
    @State private var albumTarget: Playlist?
    @State private var artistTarget: (id: String, name: String)?

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()

            if isLoading {
                VStack(spacing: 16) {
                    ProgressView().tint(Color.ytRed)
                    Text(artistName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.appDim)
                }
            } else if let artist {
                ScrollView {
                    VStack(spacing: 0) {
                        ArtistHero(artist: artist)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : -8)

                        VStack(spacing: 28) {
                            if !artist.topSongs.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Top Songs")
                                        .sectionHeader()
                                        .padding(.horizontal, 4)

                                    LazyVStack(spacing: 1) {
                                        ForEach(Array(artist.topSongs.prefix(10).enumerated()), id: \.element.id) { i, track in
                                            TrackRow(track: track, onStartRadio: { radioTrack = $0 }, onNavigateToArtist: { id, name in
                                                artistTarget = (id, name)
                                            }, onNavigateToAlbum: { id, title, thumb in
                                                albumTarget = Playlist(id: id, title: title ?? "Album", thumbnailURL: thumb, tracks: [])
                                            })
                                                .opacity(appeared ? 1 : 0)
                                                .offset(y: appeared ? 0 : 8)
                                                .animation(
                                                    .spring(response: 0.45, dampingFraction: 0.82)
                                                        .delay(0.1 + Double(i) * 0.025),
                                                    value: appeared
                                                )
                                        }
                                    }
                                }
                            }

                            if !artist.albums.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Albums")
                                        .sectionHeader()
                                        .padding(.horizontal, 20)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        LazyHStack(spacing: 14) {
                                            ForEach(artist.albums) { album in
                                                NavigationLink(destination: PlaylistDetailView(playlist: album)) {
                                                    ArtistAlbumCard(playlist: album)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                    }
                                }
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 12)
                                .animation(
                                    .spring(response: 0.45, dampingFraction: 0.82).delay(0.2),
                                    value: appeared
                                )
                            }

                            if !artist.singles.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Singles")
                                        .sectionHeader()
                                        .padding(.horizontal, 20)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        LazyHStack(spacing: 14) {
                                            ForEach(artist.singles) { single in
                                                NavigationLink(destination: PlaylistDetailView(playlist: single)) {
                                                    ArtistAlbumCard(playlist: single)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                    }
                                }
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 12)
                                .animation(
                                    .spring(response: 0.45, dampingFraction: 0.82).delay(0.25),
                                    value: appeared
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 40)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 40, weight: .ultraLight))
                        .foregroundStyle(Color.appGhost)
                    Text("Could not load artist")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.appDim)
                }
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { radioTrack != nil },
            set: { if !$0 { radioTrack = nil } }
        )) {
            if let track = radioTrack {
                RadioView(sourceTrack: track)
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { albumTarget != nil },
            set: { if !$0 { albumTarget = nil } }
        )) {
            if let album = albumTarget {
                PlaylistDetailView(playlist: album)
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { artistTarget != nil },
            set: { if !$0 { artistTarget = nil } }
        )) {
            if let target = artistTarget {
                ArtistView(channelId: target.id, artistName: target.name)
            }
        }
        .navigationTitle(artist?.name ?? artistName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appBg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            do {
                artist = try await YTMusicClient.shared.fetchArtist(channelId: channelId)
            } catch {
                print("[Artist] load failed: \(error)")
            }
            isLoading = false
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { appeared = true }
        }
    }
}

// MARK: - Artist Hero

private struct ArtistHero: View {
    let artist: YTMusicClient.ArtistPage
    @State private var heroImage: UIImage?

    var body: some View {
        ZStack {
            if let img = heroImage {
                GeometryReader { _ in
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 50)
                        .overlay(Color.appBg.opacity(0.5))
                        .overlay(
                            LinearGradient(
                                colors: [Color.appBg.opacity(0), Color.appBg],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .mask(
                            LinearGradient(
                                colors: [.black, .black, .black.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .frame(height: 280)
                .clipped()
            }

            VStack(spacing: 14) {
                if let url = artist.thumbnailURL {
                    ThumbnailView(url: url, size: 120, cornerRadius: 60)
                        .shadow(color: .black.opacity(0.7), radius: 32, y: 10)
                } else {
                    Circle()
                        .fill(Color.appSurface)
                        .frame(width: 120, height: 120)
                        .overlay(
                            Image(systemName: "music.mic")
                                .font(.system(size: 40, weight: .ultraLight))
                                .foregroundStyle(Color.appGhost)
                        )
                }

                VStack(spacing: 6) {
                    Text(artist.name)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    if let subs = artist.subscriberCount, !subs.isEmpty {
                        Text(subs)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.appFaint)
                    }

                    HStack(spacing: 16) {
                        if !artist.topSongs.isEmpty {
                            Label("\(artist.topSongs.count) songs", systemImage: "music.note")
                        }
                        if !artist.albums.isEmpty {
                            Label("\(artist.albums.count) albums", systemImage: "square.stack")
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.appGhost)
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
        .task(id: artist.thumbnailURL) {
            guard let urlStr = artist.thumbnailURL, let url = URL(string: urlStr) else { return }
            if let cached = ThumbnailCache.shared.get(urlStr) { heroImage = cached; return }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = UIImage(data: data) else { return }
            ThumbnailCache.shared.set(img, for: urlStr)
            withAnimation(.easeIn(duration: 0.4)) { heroImage = img }
        }
    }
}

// MARK: - Album Card

private struct ArtistAlbumCard: View {
    let playlist: Playlist
    @ObservedObject private var downloader = AudioDownloader.shared

    private var allDownloaded: Bool {
        !playlist.tracks.isEmpty && playlist.tracks.allSatisfy { downloader.isDownloaded($0.videoId) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                ThumbnailView(url: playlist.thumbnailURL, size: 150, cornerRadius: 12)
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 4)

                if allDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.ytRed)
                        .background(Circle().fill(Color.black).padding(-2))
                        .offset(x: -6, y: -6)
                }
            }

            Text(playlist.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(width: 150, alignment: .leading)

            if let subtitle = playlist.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appFaint)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)
            }
        }
    }
}
