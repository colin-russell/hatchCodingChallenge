// VideoListViewModel.swift
// ViewModel for infinite scrolling video list

import Foundation
import SwiftUI

@Observable
final class VideoListViewModel {
    private(set) var videos: [Video] = []
    private(set) var isLoading: Bool = false
    var error: String?
    
    private var hasLoaded: Bool = false
    private let manifestURL = URL(string: "https://cdn.dev.airxp.app/AgentVideos-HLS-Progressive/manifest.json")!
    
    init() {
        Task { await loadInitialVideos() }
    }
    
    @MainActor
    func loadInitialVideos() async {
        guard !hasLoaded else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetchedVideos = try await VideoAPIClient.shared.fetchVideos(from: manifestURL)
            videos = fetchedVideos
            hasLoaded = true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
    
    /// Loads more videos if needed (for future pagination support)
    @MainActor
    func loadMoreIfNeeded(currentVideo: Video) async {
        // For now, loads only once since manifest returns all videos.
        // Extend here for true paging if backend supports.
        if let last = videos.last, last.id == currentVideo.id, !isLoading {
            await loadInitialVideos() // In the future: replace with proper paging
        }
    }
}
