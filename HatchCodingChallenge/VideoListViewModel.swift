// VideoListViewModel.swift
// ViewModel for infinite scrolling video list

import Foundation
import SwiftUI
import Combine
import AVFoundation

final class VideoListViewModel: ObservableObject {
    @Published private(set) var videos: [Video] = []
    @Published private(set) var isLoading: Bool = false
    @Published var error: String?

    // The id of the currently playing video
    @Published var currentPlayingID: String?
    
    private var hasLoaded: Bool = false
    private let manifestURL = URL(string: "https://cdn.dev.airxp.app/AgentVideos-HLS-Progressive/manifest.json")!
    // Small LRU cache to hold a couple of AV players to avoid thrashing network/cache
    private var playbackCache: [String: VideoPlaybackModel] = [:]
    private var playbackLRU: [String] = []
    private let maxCachedPlayers = 2
    
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

    // Set which video should be playing. Pause only the previous player, start the requested one,
    // and prefetch the next video's asset (playable key) off the MainActor to warm the network/asset layer.
    @MainActor
    func setPlaying(_ video: Video) async {
        guard currentPlayingID != video.id else { return }

        // Pause previous player (if any) — avoid iterating whole array for performance
        let previousID = currentPlayingID
        currentPlayingID = video.id
        if let prev = previousID, let prevIndex = videos.firstIndex(where: { $0.id == prev }), let prevPB = videos[prevIndex].playback {
            prevPB.pause()
            prevPB.seekToStart()
        }

        // Ensure the requested video's playback is ready (reuse cache or create)
        if let idx = videos.firstIndex(where: { $0.id == video.id }) {
            let id = videos[idx].id
            if videos[idx].playback == nil {
                if let cached = playbackCache[id] {
                    videos[idx].playback = cached
                    if let pos = playbackLRU.firstIndex(of: id) { playbackLRU.remove(at: pos) }
                    playbackLRU.append(id)
                } else {
                    let pb = await MainActor.run { VideoPlaybackModel(url: videos[idx].url) }
                    videos[idx].playback = pb
                    playbackCache[id] = pb
                    playbackLRU.append(id)
                    if playbackLRU.count > maxCachedPlayers {
                        let removeId = playbackLRU.removeFirst()
                        if removeId != id {
                            if let evicted = playbackCache[removeId] {
                                evicted.shutdown()
                            }
                            playbackCache[removeId] = nil
                            if let ridx = videos.firstIndex(where: { $0.id == removeId }) {
                                videos[ridx].playback = nil
                            }
                        }
                    }
                }
            }
            if let pb = videos[idx].playback {
                pb.play()
            }
        }

        // Prefetch the next video's asset (playable key) in a detached task to warm caches/network
        var nextURLs: [URL] = []
        if let currentIndex = videos.firstIndex(where: { $0.id == video.id }) {
            let aheadCount = 1 // warm next 1 video; increase to 2 if desired
            for offset in 1...aheadCount {
                let ni = currentIndex + offset
                if ni < videos.count {
                    nextURLs.append(videos[ni].url)
                }
            }
        }

        if !nextURLs.isEmpty {
            let urlsToPrefetch = nextURLs
            Task.detached {
                for u in urlsToPrefetch {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let asset = AVURLAsset(url: u)
                        asset.loadValuesAsynchronously(forKeys: ["playable"]) {
                            // ignore errors, this is a warm-up
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }

    // Ensure a playback exists for a video (creates on MainActor)
    @MainActor
    func ensurePlayback(for video: Video) async {
        guard let idx = videos.firstIndex(where: { $0.id == video.id }) else { return }
        if videos[idx].playback == nil {
            let id = videos[idx].id
            if let cached = playbackCache[id] {
                videos[idx].playback = cached
                if let pos = playbackLRU.firstIndex(of: id) { playbackLRU.remove(at: pos) }
                playbackLRU.append(id)
            } else {
                let pb = await MainActor.run { VideoPlaybackModel(url: videos[idx].url) }
                videos[idx].playback = pb
                playbackCache[id] = pb
                playbackLRU.append(id)
                if playbackLRU.count > maxCachedPlayers {
                    let removeId = playbackLRU.removeFirst()
                    if let evicted = playbackCache[removeId] {
                        evicted.shutdown()
                    }
                    playbackCache[removeId] = nil
                    if let ridx = videos.firstIndex(where: { $0.id == removeId }) {
                        videos[ridx].playback = nil
                    }
                }
            }
        }
    }

    // Cleanup playback for a video (pause and nil out)
    @MainActor
    func cleanupPlayback(for video: Video) async {
        guard let idx = videos.firstIndex(where: { $0.id == video.id }) else { return }
        if let pb = videos[idx].playback {
            pb.pause()
            pb.seekToStart()
        }
        let id = videos[idx].id
        // Remove from LRU and maybe keep it in cache depending on cache size
        if let pos = playbackLRU.firstIndex(of: id) {
            playbackLRU.remove(at: pos)
        }
        // If cache is already over capacity, drop this playback; otherwise keep it cached
        if playbackCache[id] != nil {
            if playbackLRU.count >= maxCachedPlayers {
                playbackCache[id] = nil
                videos[idx].playback = nil
            } else {
                // keep cached but detach from video model
                videos[idx].playback = nil
            }
        } else {
            videos[idx].playback = nil
        }
    }
}
