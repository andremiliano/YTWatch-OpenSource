# Contributing to YTWatch

First off, thank you for considering contributing to YTWatch! It's people like you that make the open-source community such an amazing place to learn, inspire, and create.

## 🛠 Architecture Overview

YTWatch follows a clean MVVM structure with an emphasis on native SwiftUI patterns.
- `iOS/Services` & `watchOS/Services`: Core business logic (Singletons or `@MainActor` ObservableObjects).
- `Shared`: Models (`Track`, `Playlist`, `WatchMessage`) and pure logic (`PlaybackQueue`).
- `watchOS/Views`: The UI for the Watch app.

### Key Components to Understand
- **`YTMusicClient.swift`**: Handles all communication with YouTube Music. It uses a `WKWebView` to capture auth cookies and sends standard HTTP requests.
- **`WatchFileReceiver.swift`**: The heartbeat of the Watch app. It manages incoming `WCSession` files, handles local disk storage, and maintains the `cachedAvailablePlaylists` so the UI never blocks.
- **`WatchPlayer.swift`**: Wraps `AVPlayer`. To prevent memory issues on the Watch, it reuses a *single* `AVPlayer` instance across tracks, swapping `AVPlayerItem`s.

## 🐛 Reporting Bugs

If you find a bug, please create an issue on GitHub. Include:
- iOS and watchOS versions.
- A clear, reproducible step-by-step guide.
- Expected behavior vs. actual behavior.

## 🚀 Pull Requests

1. Fork the repo and create your branch from `main`.
2. Run `xcodegen generate` to ensure you're working with a fresh `.xcodeproj`.
3. If you've added code that should be tested, add tests.
4. Ensure the test suite passes (`PlaybackCoreTests`).
5. Format your commit messages following [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).
   - `feat: add awesome new feature`
   - `fix: resolve crash on launch`
   - `refactor: clean up WatchPlayer logic`

## 💬 Code Style
- Use Swift 6 concurrency (`async/await`, `@MainActor`) instead of completion handlers where possible.
- Avoid force unwrapping (`!`) entirely.
- Add SwiftDoc comments (`///`) to any non-private functions or complex logic.
