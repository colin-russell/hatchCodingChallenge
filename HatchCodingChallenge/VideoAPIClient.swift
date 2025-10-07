import Foundation
import SwiftUI
import AVKit

@Observable class VideoPlaybackModel {
    let player: AVPlayer
    init(url: URL) {
        self.player = AVPlayer(url: url)
    }
}

struct Video: Identifiable, Equatable {
    let id: String
    let playback: VideoPlaybackModel

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
                // Some URLs may share the same filename but differ by path/query,
                // so filename-only IDs caused duplicate IDs and view reuse.
                let id = videoURL.absoluteString
                let playback = await MainActor.run { VideoPlaybackModel(url: videoURL) }
                videos.append(Video(id: id.isEmpty ? String(idx) : id, playback: playback))
            }

            return videos
        } catch is DecodingError {
            throw VideoAPIError.decodingFailed
        } catch {
            throw VideoAPIError.network(error)
        }
    }
}
