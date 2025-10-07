// VideoListViewModel.swift
// ViewModel for infinite scrolling video list

import Foundation
import SwiftUI
import Combine
import AVFoundation
import os

final class VideoListViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.colinrussell.HatchCodingChallenge", category: "VideoListViewModel")
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
            // Immediately ensure playback for the first video and start it to avoid
            // a startup race where the view's geometry or preference-based visibility
            // hasn't been established yet. Running this on the MainActor is safe
            // because this function is already @MainActor.
            if let first = videos.first, currentPlayingID == nil {
                await ensurePlayback(for: first)
                await setPlaying(first)
            }
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
                    var v = videos[idx]
                    v.playback = cached
                    videos[idx] = v
                    if let pos = playbackLRU.firstIndex(of: id) { playbackLRU.remove(at: pos) }
                    playbackLRU.append(id)
                } else {
                    let pb = await MainActor.run { VideoPlaybackModel(url: videos[idx].url) }
                    var v = videos[idx]
                    v.playback = pb
                    videos[idx] = v
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
                                var rv = videos[ridx]
                                rv.playback = nil
                                videos[ridx] = rv
                            }
                        }
                    }
                }
            }
            if let pb = videos.first(where: { $0.id == video.id })?.playback {
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
                        // Warm the asset's playable key using the older async API which
                        // is compatible across SDKs. This is best-effort and errors are ignored.
                        let asset = AVURLAsset(url: u)
                        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                            asset.loadValuesAsynchronously(forKeys: ["playable"]) {
                                continuation.resume()
                            }
                        }
                }
            }
        }
    }

    // Attempt to set the given video as playing only when its playback is ready.
    // This polls the playback's readiness for a short timeout to avoid switching
    // to a player that will immediately show a loading spinner or black screen.
    @MainActor
    func attemptSetPlayingIfReady(_ video: Video, timeout: TimeInterval = 0.75) async {
        await ensurePlayback(for: video)

        guard let idx = videos.firstIndex(where: { $0.id == video.id }), let pb = videos[idx].playback else {
            // couldn't get playback, so no-op
            return
        }

        // Poll for readiness for up to `timeout` seconds, checking at 50ms intervals.
    let intervalNs: UInt64 = 50_000_000 // 50ms in ns
    let intervalSeconds = Double(intervalNs) / 1_000_000_000.0
    let maxIterations = Int((timeout / intervalSeconds).rounded())
        var ready = await pb.isReadyForPlayback()
        var iter = 0
        while !ready && iter < maxIterations {
            try? await Task.sleep(nanoseconds: intervalNs)
            ready = await pb.isReadyForPlayback()
            iter += 1
        }

        // If ready (or timed out), switch to this video. If not ready then don't switch.
        if ready || iter >= maxIterations {
            await setPlaying(video)
        } else {
            Self.logger.debug("attemptSetPlayingIfReady: video not ready, skipping switch for id=\(video.id)")
        }
    }

    // Ensure a playback exists for a video (creates on MainActor)
    @MainActor
    func ensurePlayback(for video: Video) async {
        guard let idx = videos.firstIndex(where: { $0.id == video.id }) else { return }
        if videos[idx].playback == nil {
            let id = videos[idx].id
            if let cached = playbackCache[id] {
                var v = videos[idx]
                v.playback = cached
                videos[idx] = v
                if let pos = playbackLRU.firstIndex(of: id) { playbackLRU.remove(at: pos) }
                playbackLRU.append(id)
            } else {
                let pb = await MainActor.run { VideoPlaybackModel(url: videos[idx].url) }
                var v = videos[idx]
                v.playback = pb
                videos[idx] = v
                playbackCache[id] = pb
                playbackLRU.append(id)
                if playbackLRU.count > maxCachedPlayers {
                    let removeId = playbackLRU.removeFirst()
                    if let evicted = playbackCache[removeId] {
                        evicted.shutdown()
                    }
                    playbackCache[removeId] = nil
                    if let ridx = videos.firstIndex(where: { $0.id == removeId }) {
                        var rv = videos[ridx]
                        rv.playback = nil
                        videos[ridx] = rv
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
                var v = videos[idx]
                v.playback = nil
                videos[idx] = v
            } else {
                // keep cached but detach from video model
                var v = videos[idx]
                v.playback = nil
                videos[idx] = v
            }
        } else {
            var v = videos[idx]
            v.playback = nil
            videos[idx] = v
        }
    }
}
