import Foundation
import SwiftUI
import AVKit

@MainActor
@Observable class VideoPlaybackModel {
    let player: AVPlayer
    // Current playback error (if any)
    var error: String?

    private var playerItem: AVPlayerItem?
    private var statusObserver: NSKeyValueObservation?
    private var notificationTokens: [Any] = []

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        self.playerItem = item
        self.player = AVPlayer(playerItem: item)

        // KVO for status to detect failures
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { await MainActor.run {
                if item.status == .failed {
                    self?.error = item.error?.localizedDescription ?? "Unknown playback error"
                } else {
                    // clear error when becomes ready/unknown
                    self?.error = nil
                }
            }}
        }

        // Notification for failed-to-play-to-end
        let failedToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            Task { await MainActor.run { self?.error = err?.localizedDescription ?? "Failed to play to end" } }
        }
        notificationTokens.append(failedToken)

        // Playback stalled notification
        let stalledToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
            Task { await MainActor.run { self?.error = "Playback stalled" } }
        }
        notificationTokens.append(stalledToken)
    }

    // Helpers so playback can be controlled safely from MainActor
    @MainActor
    func play() {
        player.play()
    }

    @MainActor
    func pause() {
        player.pause()
    }

    @MainActor
    func seekToStart() {
        player.seek(to: .zero)
    }

    deinit {
        // Note: cleanup of KVO/notification tokens must run on the MainActor because
        // these properties are MainActor-isolated. deinit is not executed on the
        // MainActor in all cases, so referencing those properties here caused
        // compilation errors. To avoid that, we intentionally avoid synchronous
        // access here. If you want to perform explicit cleanup, schedule it on
        // the MainActor from a controlled spot (e.g. when removing a playback from
        // the cache). For now we rely on system cleanup when items are deallocated.
    }
}

struct Video: Identifiable, Equatable {
    let id: String
    let url: URL
    var playback: VideoPlaybackModel?

    static func == (lhs: Video, rhs: Video) -> Bool {
        lhs.id == rhs.id
    }
}

private struct VideoManifest: Decodable {
    let videos: [URL]
}

enum VideoAPIError: Error, LocalizedError {
    case invalidURL
    case decodingFailed
    case network(Error)
    case unknown
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The provided URL is invalid."
        case .decodingFailed: return "Failed to decode video data."
        case .network(let error): return error.localizedDescription
        case .unknown: return "An unknown error occurred."
        }
    }
}

actor VideoAPIClient {
    static let shared = VideoAPIClient()
    private let session: URLSession
    
    init(session: URLSession = .shared) {
        self.session = session
    }
    
    /// Fetches videos from the provided manifest URL.
    func fetchVideos(from url: URL) async throws -> [Video] {
        do {
            let (data, _) = try await session.data(from: url)

            // VideoManifest's Decodable conformance is main-actor-isolated in this
            // project's default isolation. Decode on the MainActor to satisfy
            // actor isolation requirements.
            let manifest = try await MainActor.run { try JSONDecoder().decode(VideoManifest.self, from: data) }

            // VideoPlaybackModel initializer is also main-actor-isolated; construct
            // playback objects on the MainActor. Use an async loop so we can await
            // inside the iteration.
            var videos: [Video] = []
            for (idx, videoURL) in manifest.videos.enumerated() {
                // Use the full absoluteString as the id to ensure uniqueness
                let id = videoURL.absoluteString
                videos.append(Video(id: id.isEmpty ? String(idx) : id, url: videoURL, playback: nil))
            }

            return videos
        } catch is DecodingError {
            throw VideoAPIError.decodingFailed
        } catch {
            throw VideoAPIError.network(error)
        }
    }
}
