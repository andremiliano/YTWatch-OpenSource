# YTWatch ⌚️🎶

An open-source, fully native Apple Watch companion app for YouTube Music.

YTWatch syncs your favorite YouTube Music playlists and albums directly to your Apple Watch for **true standalone offline playback** — no iPhone required once music is synced.

## ✨ Features

- **Standalone Offline Playback:** Leave your phone at home. YTWatch stores audio directly on your Apple Watch.
- **Native SwiftUI:** Built 100% in SwiftUI, no cross-platform overhead.
- **No API Key Required:** Uses direct cookie-based authentication via an internal web view — sign in with your own Google account, nothing to register with Google/YouTube.
- **Battery & Storage Optimized:** A single reused `AVPlayer`, lazy-loading file scans, and streamed downloads avoid the memory (Jetsam) crashes that plague naive watchOS audio apps.
- **Self-Healing Sync:** Corrupt or missing downloads are detected on launch and re-fetched automatically — phone and Watch libraries stay in sync.
- **Shuffle All / Auto-Play Similar / Queue Editing:** Play across your whole downloaded library, keep music going when a playlist ends, and reorder what's up next — all from the Watch.

## 🧩 How it works

YTWatch has three moving pieces:

1. **iPhone app** — signs in to YouTube Music, browses your library, and requests downloads.
2. **A small Python server you run on your Mac** ([`Scripts/server.py`](Scripts/server.py)) — uses [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) to fetch audio for whatever the iPhone app requests. This is what keeps YTWatch itself free of scraping/download logic and easy to audit.
3. **Watch app** — receives synced tracks over `WatchConnectivity` and plays them entirely offline, with Bluetooth headphones connected directly to the Watch.

There is no cloud backend and nothing is ever uploaded anywhere — the Mac server only talks to your iPhone over your own local Wi-Fi.

## 🚀 Quick Start (build from source)

This is the recommended, fully-supported way to run YTWatch — see [why a prebuilt IPA isn't offered](#-prebuilt-ipa--sideloading) below.

### Requirements

- Mac with **Xcode 16+**
- **iPhone (iOS 17+)** paired with **Apple Watch (watchOS 10+)**
- A free or paid **Apple Developer account** (a free Apple ID works — see [signing notes](#code-signing-notes))
- **Python 3.10+** on the Mac, for the download server
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — generates the `.xcodeproj` deterministically, so it isn't committed to git
- Mac and iPhone on the **same Wi-Fi network** when downloading

### 1. Clone and generate the project

```bash
git clone https://github.com/andremiliano/YTWatch-OpenSource.git
cd YTWatch-OpenSource
./Scripts/setup.sh
```

`setup.sh` installs XcodeGen/yt-dlp if missing, runs `xcodegen generate`, and opens the project in Xcode. (Just want the manual steps? `xcodegen generate && open YTWatch.xcodeproj`.)

### 2. Set your signing team

In Xcode → project settings → **Signing & Capabilities**, pick your Apple ID/Team for **both** the `YTWatch` and `YTWatch Watch App` targets. Signing is left unconfigured in the repo on purpose — see [signing notes](#code-signing-notes).

### 3. Build and run

Plug in your iPhone (Watch paired and nearby), select the `YTWatch` scheme, target your iPhone as the destination, and hit **Run** (⌘R). Xcode installs both the iPhone app and the paired Watch app in one step.

### 4. Start the download server on your Mac

```bash
python3 Scripts/server.py
```

It prints a URL like `http://192.168.1.50:8765`. Enter that in the iPhone app's **Settings** tab and tap **Check Connection**.

### 5. Sign in, download, sync

Sign in with your Google account in the iPhone app, open a playlist, **Download All**, then **Sync to Watch**. Once synced, put on the Watch, connect Bluetooth audio directly to it, and play — the phone is no longer needed.

Full walkthrough with troubleshooting: [Scripts/README.md](Scripts/README.md).

### Code signing notes

The project ships with no `DEVELOPMENT_TEAM` or signing style committed, so it builds cleanly for anyone regardless of team. A **free Apple ID** works for local device installs — the app just needs to be re-installed from Xcode every 7 days as the free provisioning profile expires. A **paid Apple Developer account ($99/yr)** removes that limit. Either way, signing is something only you configure locally — it's never something this repo needs to know about.

## 📦 Prebuilt IPA / Sideloading

A signed, ready-to-install `.ipa` isn't published for two reasons:

1. **Signing doesn't transfer.** An IPA signed with someone else's Apple Developer certificate only installs on devices registered to that account (or expires in 7 days under a free account). There's no signature that "just works" for an arbitrary stranger's phone — you'd need to build with your own Apple ID either way.
2. **The Watch companion app doesn't reliably install via sideloading tools.** Tools like [AltStore](https://faq.altstore.io/), [SideStore](https://github.com/SideStore/SideStore), and [Sideloadly](https://sideloadly.io/) can resign and install the **iPhone** app with your own Apple ID, but the paired **Watch app only auto-deploys when installed through Xcode** (or TestFlight/App Store, which don't apply to this project). Sideloading the IPA alone would typically leave you with the iPhone app but no Watch app — which defeats the point of YTWatch.

If you still want to try sideloading (e.g. to try the iPhone-side UI without installing Xcode), you can build an unsigned IPA yourself:

```bash
xcodebuild -project YTWatch.xcodeproj -scheme YTWatch -configuration Release \
  -archivePath build/YTWatch.xcarchive archive CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
cd build/YTWatch.xcarchive/Products/Applications && mkdir -p Payload && cp -r YTWatch.app Payload/
zip -r ../../../YTWatch.ipa Payload
```

Then sign/install it with Sideloadly or AltServer using your own Apple ID. Again: expect the Watch app to be missing — building from source with Xcode is the only path that reliably gets YTWatch onto your Watch.

## 🔒 Privacy & Security

- **Direct connection:** all authentication and downloading happens between your devices and Google's/YouTube's own servers — nothing passes through a third party.
- **No telemetry:** zero analytics, tracking, or crash reporting.
- **Local storage:** session cookies live in the iOS Keychain and never leave your device.

## 🤝 Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## ⚖️ Disclaimer

**Educational purposes only.** YTWatch is a third-party project, **not affiliated with, endorsed by, or sponsored by Google LLC or YouTube**. It acts as a standard web client and does not circumvent DRM. Use your own YouTube Music account (Premium may be required depending on region/usage). The developers assume no liability for how you use this software.

## 📝 License

GPL-3.0 — see [LICENSE](LICENSE). This keeps YTWatch free and open-source, and prevents commercial closed-source forks.
