import Foundation

// Messages passed over WatchConnectivity (context / sendMessage)
enum WatchMessageKey: String {
    case type
    case payload
}

enum WatchMessageType: String, Codable {
    case playlistIndex   // iPhone → Watch: updated playlist metadata
    case syncProgress    // iPhone → Watch: how many files transferred
    case playCommand     // Watch → iPhone: (future) play on phone
    case trackMetadata   // attached to each file transfer as metadata
    case deleteTrack     // iPhone → Watch: delete a track from watch
    case syncVerify      // iPhone → Watch: request inventory of track IDs on watch
    case syncInventory   // Watch → iPhone: respond with track IDs actually on disk
    case directDownload  // iPhone → Watch: stream URL for Watch to download directly via WiFi
    case downloadResult  // Watch → iPhone: result of a direct download attempt
    case requestRedownload // Watch → iPhone: these videoIds are missing/corrupt, please re-send
}

/// Sent from iPhone to Watch — Watch downloads audio directly over WiFi
struct DirectDownloadPayload: Codable {
    let track: Track
    let playlistId: String
    let playlistTitle: String
    let indexInPlaylist: Int
    let streamURL: String
    let headers: [String: String]
    let thumbnailDownloadURL: String?
}

struct TrackTransferMetadata: Codable {
    let track: Track
    let playlistId: String
    let playlistTitle: String
    let indexInPlaylist: Int
}
