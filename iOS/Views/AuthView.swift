import SwiftUI
import WebKit

struct AuthView: View {
    @ObservedObject private var client = YTMusicClient.shared
    @State private var showWebView = false
    @State private var glowPulse = false
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()

            // Animated radial glow
            RadialGradient(
                colors: [
                    Color.ytRed.opacity(glowPulse ? 0.22 : 0.10),
                    Color.appBg
                ],
                center: UnitPoint(x: 0.5, y: 0.0),
                startRadius: 0,
                endRadius: 480
            )
            .ignoresSafeArea()
            .animation(
                .easeInOut(duration: 3.5).repeatForever(autoreverses: true),
                value: glowPulse
            )

            VStack(spacing: 0) {
                Spacer()

                // Wordmark
                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .fill(Color.ytRed.opacity(0.12))
                            .frame(width: 96, height: 96)
                        Circle()
                            .fill(Color.ytRed.opacity(0.08))
                            .frame(width: 72, height: 72)
                        Image(systemName: "waveform")
                            .font(.system(size: 36, weight: .ultraLight))
                            .foregroundStyle(Color.ytRed)
                    }
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)

                    VStack(spacing: 8) {
                        Text("YTWATCH")
                            .font(.system(size: 34, weight: .black))
                            .tracking(10)
                            .foregroundStyle(.white)

                        Text("YouTube Music  ·  Apple Watch")
                            .font(.system(size: 12, weight: .medium))
                            .tracking(2.5)
                            .foregroundStyle(Color.appFaint)
                    }
                    .offset(y: appeared ? 0 : 12)
                    .opacity(appeared ? 1 : 0)
                }

                Spacer()

                // CTA
                VStack(spacing: 16) {
                    Button(action: { showWebView = true }) {
                        HStack(spacing: 10) {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 17))
                            Text("Continue with Google")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Text("Your credentials are stored securely in Keychain and never leave your device.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appGhost)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 52)
                .offset(y: appeared ? 0 : 24)
                .opacity(appeared ? 1 : 0)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            glowPulse = true
            withAnimation(.spring(response: 0.7, dampingFraction: 0.75).delay(0.1)) {
                appeared = true
            }
        }
        .sheet(isPresented: $showWebView) {
            GoogleLoginSheet()
        }
    }
}

struct GoogleLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var readyToDone = false   // true once we land on music.youtube.com
    @State private var saving = false
    @State private var warningDismissed = false

    var body: some View {
        NavigationStack {
            ZStack {
                WebLoginView(onReady: { readyToDone = true }) { cookies in
                    saving = true
                    Task { @MainActor in
                        YTMusicClient.shared.saveCookies(cookies)
                        dismiss()
                    }
                }

                // Passkey warning overlay — shown before user interacts
                if !warningDismissed {
                    PasskeyWarningBanner { warningDismissed = true }
                }

                if saving {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("Signing in…")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
            }
            .navigationTitle("Sign In to Google")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        // Manual harvest — in case auto-detect didn't fire
                        saving = true
                        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                            let authCookies = cookies.filter {
                                $0.domain.hasSuffix(".youtube.com") || $0.domain.hasSuffix(".google.com")
                            }
                            Task { @MainActor in
                                if !authCookies.isEmpty {
                                    YTMusicClient.shared.saveCookies(authCookies)
                                }
                                dismiss()
                            }
                        }
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(readyToDone ? Color.ytRed : Color.appFaint)
                    .disabled(!readyToDone)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Passkey Warning

private struct PasskeyWarningBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack {
            Spacer()

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.system(size: 16))
                    Text("Passkeys not supported")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Text("This in-app browser can't use passkeys — it's a system limitation with embedded web views on iOS. Sign in with your **Google password** instead.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(white: 0.7))
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onDismiss) {
                    Text("Got it")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(.white)
                        .clipShape(Capsule())
                }
            }
            .padding(20)
            .background(Color(white: 0.1))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color(white: 1, opacity: 0.08), lineWidth: 0.5)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
            .shadow(color: .black.opacity(0.5), radius: 24, y: -8)
        }
        .background(Color.black.opacity(0.45).ignoresSafeArea())
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Web View

struct WebLoginView: UIViewRepresentable {
    var onReady: (() -> Void)? = nil
    var onLoginComplete: ([HTTPCookie]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onReady: onReady, onComplete: onLoginComplete) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
        let url = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https://music.youtube.com")!
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onReady: (() -> Void)?
        let onComplete: ([HTTPCookie]) -> Void
        private var didComplete = false

        init(onReady: (() -> Void)?, onComplete: @escaping ([HTTPCookie]) -> Void) {
            self.onReady = onReady
            self.onComplete = onComplete
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let urlString = webView.url?.absoluteString else { return }

            // Enable Done button as soon as we're on any music.youtube.com page
            if urlString.hasPrefix("https://music.youtube.com"),
               !urlString.contains("/ServiceLogin"), !urlString.contains("/signin") {
                DispatchQueue.main.async { self.onReady?() }
            }

            // Auto-complete only at the clean home page + require SAPISID cookie
            guard !didComplete,
                  urlString.hasPrefix("https://music.youtube.com"),
                  !urlString.contains("/ServiceLogin"),
                  !urlString.contains("/signin") else { return }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak webView] in
                guard let self, let webView else { return }
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    let authCookies = cookies.filter {
                        $0.domain.hasSuffix(".youtube.com") || $0.domain.hasSuffix(".google.com")
                    }
                    // Must have SAPISID — without it the API calls will 400
                    guard authCookies.contains(where: { $0.name == "SAPISID" }) else { return }
                    self.didComplete = true
                    DispatchQueue.main.async { self.onComplete(authCookies) }
                }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
        }
    }
}
