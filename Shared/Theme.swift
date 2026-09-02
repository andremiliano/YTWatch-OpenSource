import SwiftUI
import UIKit

// MARK: - Color System

extension Color {
    static let ytRed        = Color(red: 1.0,  green: 0.09, blue: 0.27)   // #FF1745
    static let appBg        = Color(red: 0.047, green: 0.047, blue: 0.047) // #0C0C0C
    static let appSurface   = Color(red: 0.094, green: 0.094, blue: 0.094) // #181818
    static let appElevated  = Color(red: 0.141, green: 0.141, blue: 0.141) // #242424
    static let appBorder    = Color(white: 1.0, opacity: 0.06)
    static let appDim       = Color(white: 1.0, opacity: 0.55)
    static let appFaint     = Color(white: 1.0, opacity: 0.28)
    static let appGhost     = Color(white: 1.0, opacity: 0.12)
}

// MARK: - View Modifiers

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.appBorder, lineWidth: 0.5)
            )
    }
}

struct SectionHeaderStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 10, weight: .semibold))
            .tracking(2.5)
            .foregroundStyle(Color.appFaint)
            .textCase(.uppercase)
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardStyle()) }
    func sectionHeader() -> some View { modifier(SectionHeaderStyle()) }
}

// MARK: - Button Styles

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(configuration.isPressed ? Color.white.opacity(0.88) : .white)
            .clipShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    var tint: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint.opacity(configuration.isPressed ? 0.5 : 0.8))
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(tint.opacity(configuration.isPressed ? 0.1 : 0.07))
            .clipShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 44
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .background(Color.appElevated.opacity(configuration.isPressed ? 0.5 : 1))
            .clipShape(Circle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Reusable Components

struct StatusBadge: View {
    let icon: String
    let color: Color

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(4)
            .background(color.opacity(0.15))
            .clipShape(Circle())
    }
}

// Thread-safe in-memory image cache to avoid re-downloading and re-decoding thumbnails.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 40 * 1024 * 1024  // 40 MB
        c.countLimit = 250
        return c
    }()

    func get(_ url: String) -> UIImage? { cache.object(forKey: url as NSString) }
    func set(_ image: UIImage, for url: String) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: url as NSString, cost: cost)
    }
}

struct ThumbnailView: View {
    let url: String?
    var size: CGFloat = 52
    var cornerRadius: CGFloat = 8

    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.appElevated
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.3, weight: .light))
                        .foregroundStyle(Color.appFaint)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) {
            guard let urlStr = url, !urlStr.isEmpty else { return }
            if let cached = ThumbnailCache.shared.get(urlStr) { image = cached; return }
            guard let request = URL(string: urlStr),
                  let (data, _) = try? await URLSession.shared.data(from: request),
                  let decoded = UIImage(data: data) else { return }
            ThumbnailCache.shared.set(decoded, for: urlStr)
            image = decoded
        }
    }
}
