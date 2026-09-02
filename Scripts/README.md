# YTWatch — Setup Guide

## Prerequisites

- Mac with Xcode 15+
- iPhone (iOS 17+) paired with Apple Watch (watchOS 10+)
- Paid Apple Developer account ($99/yr) — needed for Watch deployment
- Python 3.10+ on Mac
- yt-dlp on Mac: `pip3 install yt-dlp flask`
- Both Mac and iPhone on the **same Wi-Fi network** when downloading

---

## Step 1 — Build & Install the App

```bash
cd YTWatch
xcodegen generate       # regenerate project if you edit project.yml
open YTWatch.xcodeproj
```

In Xcode:
1. Select the `YTWatch` scheme (iPhone target)
2. Set your **Team** in Signing & Capabilities for both targets
   - `YTWatch` → your Apple ID
   - `YTWatch Watch App` → same Apple ID
3. Plug in your iPhone (watch must be paired and nearby)
4. Select your iPhone as the destination
5. **Product → Run** (⌘R)

Xcode installs both the iPhone app and Watch app automatically.

---

## Step 2 — Start the Download Server

On your Mac (same Wi-Fi as iPhone):

```bash
pip3 install yt-dlp
python3 Scripts/server.py
```

Note the IP it prints, e.g. `http://192.168.1.50:8765`

---

## Step 3 — Configure the iPhone App

1. Open **YTWatch** on your iPhone
2. Sign in with your Google account (the one with YouTube Music)
3. Go to **Settings** tab
4. Enter the server URL from Step 2
5. Tap **Check Connection** — should show "Connected"

---

## Step 4 — Download & Sync

1. **Library** tab → pick a playlist
2. Tap **Download All** — waits for server to fetch each track (~10–30s per track)
3. Once downloaded, tap **Sync to Watch**
4. Wait for transfer (keep iPhone near Watch, both on charger is fastest)

---

## Step 5 — Run Without Your Phone

1. Put on Apple Watch
2. Connect Bluetooth headphones/AirPods to the watch directly
3. Open **YTWatch** on the watch
4. Select a playlist → tap a track
5. Play icon appears — audio plays from watch storage
6. Digital Crown scrubs the timeline
7. Headphone controls (play/pause/skip) work via `MPRemoteCommandCenter`

---

## File Structure

```
YTWatch/
├── project.yml              ← XcodeGen config (edit bundle IDs here)
├── Config/
│   ├── iOS-Info.plist
│   ├── watchOS-Info.plist
│   ├── iOS.entitlements
│   └── watchOS.entitlements
├── Shared/                  ← Code shared between iOS + watchOS
│   └── Models/
├── iOS/                     ← iPhone app
│   ├── App/
│   ├── Services/
│   └── Views/
├── watchOS/                 ← Watch app
│   ├── App/
│   ├── Services/
│   └── Views/
└── Scripts/
    └── server.py            ← Mac download server
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| "Not Signed In" on watch | Re-sign in on iPhone, then re-sync |
| Watch app not installing | Confirm both targets have same Team in Signing |
| Download fails | Check server is running, IP is correct, same Wi-Fi |
| No audio on watch | Confirm Bluetooth headphones connected *to watch*, not phone |
| Transfer stuck | Keep iPhone unlocked + near watch during transfer |
| `yt-dlp` not found | `pip3 install yt-dlp` or `brew install yt-dlp` |

---

## Bundle ID

Default bundle ID is `com.andre.ytwatch`. Change in `project.yml` under
`settings.base` or per-target, then re-run `xcodegen generate`.

---

## Storage

Watch music is stored in the app's Documents/Audio directory.
The Settings tab (iPhone) shows track count and lets you clear downloads.
Watch storage used: ~4MB per track at 128kbps.
