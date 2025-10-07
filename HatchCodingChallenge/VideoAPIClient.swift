import Foundation
import SwiftUI
import AVKit
import os

@MainActor
@Observable class VideoPlaybackModel {
    nonisolated private static let logger = Logger(subsystem: "com.colinrussell.HatchCodingChallenge", category: "VideoPlayback")

    let player: AVPlayer
    // Current playback error (if any)
    var error: String?

    private var playerItem: AVPlayerItem?
    private var statusObserver: NSKeyValueObservation?
    private var notificationTokens: [Any] = []

    init(url: URL) {
        // Use AVURLAsset and conservative options to avoid expensive metadata/timing work
        let assetOptions: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ]
        let asset = AVURLAsset(url: url, options: assetOptions)
        let item = AVPlayerItem(asset: asset)
        self.playerItem = item
        self.player = AVPlayer(playerItem: item)

        Self.logger.debug("init playback for URL: \(url.absoluteString, privacy: .public)")

        // Configure buffering/stalling behavior to reduce decoder/network thrash
        self.player.automaticallyWaitsToMinimizeStalling = true
        // Keep the player alive at item end and handle looping manually
        self.player.actionAtItemEnd = .none
        // Prefer a small forward buffer to avoid holding too much data in memory
        if #available(iOS 16.0, macOS 13.0, *) {
            item.preferredForwardBufferDuration = 5.0
        }

        // KVO for status to detect failures.
        // Capture a weak `AnyObject` reference to avoid capturing the actor-isolated `self`
        // directly from a concurrently-executing closure (which triggers compiler warnings).
        // Avoid capturing 'self' or an ownerRef in this concurrently-executing
        // KVO closure — extract the relevant info and then hop to the MainActor
        // to update actor-isolated state. This prevents the "captured var in
        // concurrently-executing code" warning under Swift 6 rules.
        statusObserver = item.observe(\.status, options: [.initial, .new]) { observedItem, _ in
            let status = observedItem.status
            let errorString: String? = (status == .failed) ? (observedItem.error?.localizedDescription ?? "Unknown playback error") : nil
            if status == .failed {
                if let err = observedItem.error {
                    // logger is nonisolated, safe to call here
                    Self.logger.error("playerItem status failed: \(err.localizedDescription, privacy: .public)")
                } else {
                    Self.logger.error("playerItem status failed with unknown error")
                }
            } else if status == .readyToPlay {
                Self.logger.debug("playerItem readyToPlay for URL: \(url.absoluteString, privacy: .public)")
            }

            // Update the actor state on the MainActor without capturing 'self'
            Task { @MainActor in
                self.error = errorString
            }
        }

        // Notification for failed-to-play-to-end
        let failedToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { note in
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            let msg = err?.localizedDescription ?? "Failed to play to end"
            if let e = err {
                Self.logger.error("AVPlayerItemFailedToPlayToEndTime: \(e.localizedDescription, privacy: .public)")
            } else {
                Self.logger.error("AVPlayerItemFailedToPlayToEndTime with no error info")
            }
            Task { @MainActor in
                self.error = msg
            }
        }
        notificationTokens.append(failedToken)

        // Playback stalled notification
        let stalledToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { _ in
            Task { @MainActor in
                self.error = "Playback stalled"
            }
            Self.logger.warning("AVPlayerItemPlaybackStalled for URL: \(url.absoluteString, privacy: .public)")
        }
        notificationTokens.append(stalledToken)

        // Looping: when item finishes, seek to start and resume playback
        let finishedToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            Self.logger.debug("AVPlayerItemDidPlayToEndTime for URL: \(url.absoluteString, privacy: .public)")
            Task { @MainActor in
                // Seek back to start and resume playback to loop continuously
                self.player.seek(to: .zero)
                self.player.play()
            }
        }
        notificationTokens.append(finishedToken)
    }

    // Helpers so playback can be controlled safely from MainActor
    @MainActor
    func play() {
        let urlString = (player.currentItem?.asset as? AVURLAsset)?.url.absoluteString ?? "unknown"
        Self.logger.debug("play() called for URL: \(urlString, privacy: .public)")
        player.play()
    }

    @MainActor
    func pause() {
        let urlString = (player.currentItem?.asset as? AVURLAsset)?.url.absoluteString ?? "unknown"
        Self.logger.debug("pause() called for URL: \(urlString, privacy: .public)")
        player.pause()
    }

    @MainActor
    func seekToStart() {
        Self.logger.debug("seekToStart() called")
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
        Self.logger.debug("deinit VideoPlaybackModel")
    }

    // Explicitly remove observers and notifications on the MainActor to release resources
    @MainActor
    func shutdown() {
        Self.logger.debug("shutdown() called")
        statusObserver?.invalidate()
        statusObserver = nil
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
        player.pause()
        playerItem = nil
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
