# YTWatch ⌚️🎶

An open-source, fully native Apple Watch companion app for YouTube Music. 

YTWatch allows you to sync your favorite YouTube Music playlists and albums directly to your Apple Watch for **true standalone offline playback** — without needing your iPhone nearby.

<div align="center">
  <!-- Placeholders for screenshots -->
  <img src="https://via.placeholder.com/200x200.png?text=Watch+Screenshot+1" width="200"/>
  <img src="https://via.placeholder.com/200x200.png?text=Watch+Screenshot+2" width="200"/>
  <img src="https://via.placeholder.com/200x200.png?text=Watch+Screenshot+3" width="200"/>
</div>

## ✨ Features

- **Standalone Offline Playback:** Leave your phone at home. YTWatch stores audio directly on your Apple Watch.
- **Lightning Fast Native UI:** Built 100% in SwiftUI for fluid animations and zero overhead.
- **Zero API Quotas:** Uses direct cookie-based authentication via an internal web view. You don't need a developer API key to build or run this!
- **Battery & Storage Optimized:** Aggressive caching, lazy-loading file structures, and memory-safe sync ensure it won't kill your Watch battery or cause Jetsam memory crashes.
- **Smart Playback Engine:** Custom AVPlayer orchestration handles YouTube's padded audio containers gracefully, skipping unplayable tracks or fake-duration stutters natively.

## 🚀 Building & Installation

Because this app utilizes internal APIs and downloads audio for offline playback, it cannot be distributed on the App Store. You must build and sideload it yourself.

### Prerequisites
- Xcode 16+
- iOS 17.0+ / watchOS 10.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (used for deterministic project generation)

### Steps

1. **Clone the repository:**
   ```bash
   git clone https://github.com/yourusername/YTWatch.git
   cd YTWatch
   ```
2. **Generate the Xcode Project:**
   ```bash
   xcodegen generate
   ```
3. **Open the project:**
   ```bash
   open YTWatch.xcodeproj
   ```
4. **Configure Code Signing:**
   - In Xcode, go to the project settings.
   - Select the **Signing & Capabilities** tab.
   - Select your personal Apple Developer Team for both the `YTWatch` and `YTWatch Watch App` targets.
5. **Build and Run:**
   - Connect your iPhone (with Apple Watch paired).
   - Select the `YTWatch` scheme and hit Run (Cmd+R).

## 🔒 Privacy & Security

YTWatch is designed to be completely private:
- **Direct Connection:** All authentication and music downloading happens directly between your device and Google's servers. 
- **No Telemetry:** Zero analytics, tracking, or crash reporting.
- **Local Storage:** Your cookies and session data are stored securely in the iOS Keychain and are never transmitted to any third-party servers.

## 🤝 Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to get started.

## ⚖️ Disclaimer

**Educational Purposes Only.**  
YTWatch is a third-party project and is **not affiliated with, endorsed by, or sponsored by Google LLC or YouTube**. This application acts as a standard web client and does not circumvent any DRM. You must use your own YouTube Music account (Premium may be required depending on your region/usage). The developers of this project assume no liability for how you use this software.

## 📝 License

This project is licensed under the **GPL-3.0 License** - see the [LICENSE](LICENSE) file for details. This ensures the app remains free and open-source forever, preventing commercial cloning.
