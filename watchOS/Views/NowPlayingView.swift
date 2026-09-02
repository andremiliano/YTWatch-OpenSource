import SwiftUI
import WatchKit

struct NowPlayingScreen: View {
    var body: some View {
        WatchKit.NowPlayingView()
            .navigationBarTitleDisplayMode(.inline)
    }
}
