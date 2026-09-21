import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject private var client = YTMusicClient.shared
    @ObservedObject private var downloader = AudioDownloader.shared
    @ObservedObject private var sync = WatchSyncManager.shared
    @State private var showLogoutConfirm = false
    @State private var showClearAllConfirm = false
    @State private var showSendRemainingConfirm = false
    @State private var showDiagnosticsShare = false
    @State private var appeared = false

    @State private var estimatedWatchStorage: String = "—"

    private func computeWatchStorage() {
        let syncedIds = sync.syncedTrackIds
        let tracks = downloader.downloadedTracks
        Task.detached {
            var totalBytes: Int64 = 0
            for id in syncedIds {
                if let url = tracks[id] {
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                    totalBytes += size
                }
            }
            let mb = Double(totalBytes) / 1_000_000
            let result = mb < 1 ? "< 1 MB" : String(format: "%.0f MB", mb)
            await MainActor.run { estimatedWatchStorage = result }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // Account card
                        SettingsSection(title: "Account") {
                            AccountRow(client: client)

                            if client.isAuthenticated {
                                Divider().background(Color.appBorder).padding(.horizontal, 14)

                                Button(action: { showLogoutConfirm = true }) {
                                    HStack {
                                        Image(systemName: "rectangle.portrait.and.arrow.right")
                                            .frame(width: 28)
                                            .foregroundStyle(.red)
                                        Text("Sign Out")
                                            .foregroundStyle(.red)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 13)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // Watch card
                        SettingsSection(title: "Apple Watch") {
                            SettingsRow(
                                icon: "applewatch",
                                iconColor: sync.isAvailable ? Color.ytRed : Color.appFaint,
                                label: "Status",
                                value: sync.isAvailable
                                    ? (sync.isWatchReachable ? "Connected" : "Paired")
                                    : "Unavailable",
                                valueColor: sync.isAvailable ? Color.ytRed : Color.appFaint
                            )

                            Divider().background(Color.appBorder).padding(.horizontal, 14)

                            SettingsRow(
                                icon: "music.note",
                                iconColor: Color.appDim,
                                label: "On Watch",
                                value: "\(sync.syncedTrackIds.count)"
                            )

                            // Downloads that aren't on the Watch and aren't on their way —
                            // mostly songs downloaded outside a playlist, which are never
                            // auto-sent. Without this row the counts looked contradictory.
                            let onlyOnPhone = sync.unsyncedDownloadCount
                            if onlyOnPhone > 0 {
                                Divider().background(Color.appBorder).padding(.horizontal, 14)

                                Button {
                                    showSendRemainingConfirm = true
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "iphone")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Color.appDim)
                                            .frame(width: 28, height: 28)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Only on iPhone")
                                                .font(.system(size: 15))
                                                .foregroundStyle(.white)
                                            Text("Tap to send to Watch")
                                                .font(.system(size: 11))
                                                .foregroundStyle(Color.appFaint)
                                        }
                                        Spacer()
                                        Text("\(onlyOnPhone)")
                                            .font(.system(size: 15))
                                            .foregroundStyle(Color.appFaint)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 13)
                                }
                                .buttonStyle(.plain)
                                .disabled(!sync.isAvailable)
                            }

                            Divider().background(Color.appBorder).padding(.horizontal, 14)

                            SettingsRow(
                                icon: "internaldrive",
                                iconColor: Color.appDim,
                                label: "Audio on Watch",
                                value: estimatedWatchStorage
                            )

                            Divider().background(Color.appBorder).padding(.horizontal, 14)

                            // Verify & Re-sync button
                            Button {
                                sync.verifySyncAndRepair()
                            } label: {
                                HStack(spacing: 12) {
                                    if sync.isVerifying {
                                        ProgressView()
                                            .tint(Color.ytRed)
                                            .scaleEffect(0.7)
                                            .frame(width: 28, height: 28)
                                    } else {
                                        Image(systemName: "checkmark.shield")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.green)
                                            .frame(width: 28, height: 28)
                                            .background(Color.green.opacity(0.12))
                                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    }

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Verify & Re-sync")
                                            .font(.system(size: 15))
                                            .foregroundStyle(.white)
                                        if let r = sync.lastVerifyResult {
                                            if r.missingOnWatch == 0 {
                                                // A snapshot, not live state — say when it was
                                                // taken so it can't read as contradicting an
                                                // active sync below it.
                                                Text("\(r.actuallyOnWatch) on Watch · checked \(r.date, style: .relative) ago")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(Color.appFaint)
                                            } else {
                                                Text("Fixed \(r.missingOnWatch) missing · re-syncing \(r.resynced)")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(.orange)
                                            }
                                        } else {
                                            Text("Check Watch has all synced tracks")
                                                .font(.system(size: 11))
                                                .foregroundStyle(Color.appFaint)
                                        }
                                    }

                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 13)
                            }
                            .buttonStyle(.plain)
                            .disabled(!sync.isAvailable || !sync.isWatchReachable || sync.isVerifying)
                            .opacity(sync.isAvailable && sync.isWatchReachable ? 1 : 0.5)

                            if !sync.transferringTrackIds.isEmpty || sync.pendingSyncCount > 0 {
                                Divider().background(Color.appBorder).padding(.horizontal, 14)

                                HStack(spacing: 12) {
                                    ProgressView()
                                        .tint(Color.ytRed)
                                        .scaleEffect(0.7)
                                        .frame(width: 28, height: 28)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Syncing to Watch")
                                            .font(.system(size: 15))
                                            .foregroundStyle(.white)
                                        let transferring = sync.transferringTrackIds.count
                                        // Tracks stay in the pending queue until the Watch
                                        // confirms them, so the queue already includes the
                                        // ones sending — don't count them twice.
                                        let waiting = max(0, sync.pendingSyncCount - transferring)
                                        Text("\(transferring) sending · \(waiting) waiting")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.appFaint)
                                        if !sync.isWatchReachable {
                                            Text("Open YTWatch on your Watch to speed this up")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.orange)
                                        }
                                    }

                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 13)
                            }
                        }

                        // Storage card
                        SettingsSection(title: "Storage") {
                            SettingsRow(
                                icon: "iphone",
                                iconColor: .blue,
                                label: "Audio on iPhone",
                                value: downloader.formattedTotalSize
                            )

                            Divider().background(Color.appBorder).padding(.horizontal, 14)

                            NavigationLink(destination: DownloadsListView()) {
                                HStack(spacing: 12) {
                                    Image(systemName: "music.note.list")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.orange)
                                        .frame(width: 28, height: 28)
                                        .background(Color.orange.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                                    Text("Downloaded Tracks")
                                        .font(.system(size: 15))
                                        .foregroundStyle(.white)

                                    Spacer()

                                    Text("\(downloader.downloadedTracks.count)")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Color.appFaint)

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Color.appGhost)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 13)
                            }
                            .buttonStyle(.plain)

                            if !downloader.downloadedTracks.isEmpty {
                                Divider().background(Color.appBorder).padding(.horizontal, 14)

                                // Repair corrupted downloads
                                Button {
                                    Task { await downloader.repairCorruptedDownloads() }
                                } label: {
                                    HStack(spacing: 12) {
                                        if downloader.isRepairing {
                                            ProgressView()
                                                .tint(Color.ytRed)
                                                .scaleEffect(0.7)
                                                .frame(width: 28, height: 28)
                                        } else {
                                            Image(systemName: "wrench.and.screwdriver")
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(.blue)
                                                .frame(width: 28, height: 28)
                                                .background(Color.blue.opacity(0.12))
                                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                        }

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(downloader.isRepairing ? "Checking downloads…" : "Repair Downloads")
                                                .font(.system(size: 15))
                                                .foregroundStyle(.white)
                                            if downloader.isRepairing {
                                                Text("\(Int(downloader.repairProgress * 100))% scanned")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(Color.appFaint)
                                            } else if let summary = downloader.lastRepairSummary {
                                                Text(summary)
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(summary.contains("Fixed") ? .orange : Color.appFaint)
                                            } else {
                                                Text("Find & re-download corrupt files")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(Color.appFaint)
                                            }
                                        }

                                        Spacer()
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 13)
                                }
                                .buttonStyle(.plain)
                                .disabled(downloader.isRepairing)

                                Divider().background(Color.appBorder).padding(.horizontal, 14)

                                Button(action: { showClearAllConfirm = true }) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.red)
                                            .frame(width: 28, height: 28)
                                            .background(Color.red.opacity(0.12))
                                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                                        Text("Clear All Downloads")
                                            .font(.system(size: 15))
                                            .foregroundStyle(.red)

                                        Spacer()
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 13)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // Watch diagnostics — the Watch sends its event log here; this is
                        // the only way to get it off the Watch, which is used away from
                        // the phone and has no readable crash logs.
                        SettingsSection(title: "Diagnostics") {
                            if let received = sync.watchDiagnosticsReceivedAt {
                                Button {
                                    showDiagnosticsShare = true
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "square.and.arrow.up")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.blue)
                                            .frame(width: 28, height: 28)
                                            .background(Color.blue.opacity(0.12))
                                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Share Watch Log")
                                                .font(.system(size: 15))
                                                .foregroundStyle(.white)
                                            Text("Received \(received.formatted(date: .abbreviated, time: .shortened))")
                                                .font(.system(size: 11))
                                                .foregroundStyle(Color.appFaint)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 13)
                                }
                                .buttonStyle(.plain)
                            } else {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("No Watch log yet")
                                        .font(.system(size: 15))
                                        .foregroundStyle(.white)
                                    Text("On the Watch: Storage → Send Diagnostics. It arrives next time the Watch is near this iPhone.")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.appFaint)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 13)
                            }
                        }

                        // About
                        SettingsSection(title: "About") {
                            SettingsRow(icon: "waveform", iconColor: Color.ytRed, label: "iPhone App", value: AppVersion.display)
                            Divider().background(Color.appBorder).padding(.horizontal, 14)
                            SettingsRow(icon: "network", iconColor: .teal, label: "Audio Source", value: "YouTube Direct")
                        }

                        Text("Audio cookies are stored in Keychain.\nApp is for personal use only.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.appGhost)
                            .multilineTextAlignment(.center)
                            .padding(.bottom, 32)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.appBg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(isPresented: $showDiagnosticsShare) {
                ShareSheet(items: [WatchSyncManager.watchDiagnosticsURL])
            }
            .alert("Send to Watch?", isPresented: $showSendRemainingConfirm) {
                Button("Send \(sync.unsyncedDownloadCount) tracks") { sync.syncUnsyncedDownloads() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("These downloads aren't on your Watch yet. They'll be added to a \"Downloads\" playlist there.")
            }
            .alert("Sign Out?", isPresented: $showLogoutConfirm) {
                Button("Sign Out", role: .destructive) { client.logout() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your saved cookies will be removed. You'll need to sign in again to sync playlists.")
            }
            .alert("Clear All Downloads?", isPresented: $showClearAllConfirm) {
                Button("Delete All", role: .destructive) { downloader.deleteAllDownloads() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove \(downloader.downloadedTracks.count) tracks (\(downloader.formattedTotalSize)) from your iPhone and Apple Watch.")
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.05)) {
                appeared = true
            }
            computeWatchStorage()
        }
    }
}

// MARK: - Components

/// System share sheet — lets the Watch log be saved to Files, AirDropped to a Mac, or
/// sent on to someone who can read it.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .sectionHeader()
                .padding(.leading, 4)

            VStack(spacing: 0) {
                content
            }
            .cardStyle()
        }
    }
}

private struct SettingsRow: View {
    let icon: String
    let iconColor: Color
    let label: String
    let value: String
    var valueColor: Color = Color.appFaint

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)
                .background(iconColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(.white)

            Spacer()

            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(valueColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
}

private struct AccountRow: View {
    @ObservedObject var client: YTMusicClient
    @State private var retrying = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.blue)
                .frame(width: 28, height: 28)
                .background(Color.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                if let name = client.userDisplayName, !name.isEmpty {
                    Text(name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Signed in to YouTube Music")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appFaint)
                } else if client.isAuthenticated {
                    Text("YouTube Music")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                    Text("Name not loaded")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appFaint)
                } else {
                    Text("Not signed in")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.appFaint)
                }
            }

            Spacer()

            if client.isAuthenticated {
                if retrying {
                    ProgressView().tint(Color.ytRed).scaleEffect(0.75)
                } else if client.userDisplayName == nil {
                    Button {
                        retrying = true
                        Task {
                            await client.fetchUserProfile()
                            retrying = false
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.appFaint)
                    }
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.ytRed)
                        .font(.system(size: 16))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
}
