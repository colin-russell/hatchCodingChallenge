import Foundation

struct Video: Identifiable, Equatable {
    let id: String
    let videoURL: URL
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
            let manifest = try JSONDecoder().decode(VideoManifest.self, from: data)
            let videos = manifest.videos.enumerated().map { idx, videoURL in
                // Use the last path component (without extension) as id if possible; else fallback to index
                let id = videoURL.deletingPathExtension().lastPathComponent
                return Video(id: id.isEmpty ? String(idx) : id, videoURL: videoURL)
            }
            return videos
        } catch is DecodingError {
            throw VideoAPIError.decodingFailed
        } catch {
            throw VideoAPIError.network(error)
        }
    }
}
