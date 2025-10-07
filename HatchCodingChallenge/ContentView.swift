//
//  ContentView.swift
//  HatchCodingChallenge
//
//  Created by Colin Russell on 2025-10-07.
//

import SwiftUI
import AVKit

// PreferenceKey to collect frames for each video cell inside the named scroll coordinate space
private struct VideoFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct ContentView: View {
    @StateObject private var viewModel = VideoListViewModel()
    @State private var scrollHeight: CGFloat = 0

    var body: some View {
        NavigationStack {
            GeometryReader { outerProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(viewModel.videos, id: \.id) { video in
                            VStack(alignment: .leading) {
                                if let playback = video.playback {
                                    VideoPlayer(player: playback.player)
                                        .frame(maxWidth: .infinity)
                                        .aspectRatio(9.0/16.0, contentMode: .fit)
                                        .cornerRadius(12)
                                } else {
                                    ZStack {
                                        Rectangle()
                                            .fill(Color.black.opacity(0.1))
                                            .aspectRatio(9.0/16.0, contentMode: .fit)
                                            .cornerRadius(12)
                                        ProgressView()
                                    }
                                    .frame(maxWidth: .infinity)
                                }

                                Text(video.id.prefix(80))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let err = video.playback?.error {
                                    Text("Error: \(err)")
                                        .font(.caption2)
                                        .foregroundColor(.red)
                                        .lineLimit(2)
                                        .padding(.top, 4)
                                }
                            }
                            .padding(.vertical, 8)
                            // Report this cell's frame (in the scroll coordinate space) via preference
                            .background(
                                GeometryReader { proxy in
                                    Color.clear
                                        .preference(key: VideoFramesKey.self, value: [video.id: proxy.frame(in: .named("scroll"))])
                                }
                            )
                            .onAppear {
                                // Keep creating playbacks lazily but don't automatically play here.
                                Task { await viewModel.ensurePlayback(for: video) }
                            }
                            .onDisappear {
                                Task { await viewModel.cleanupPlayback(for: video) }
                            }
                        }

                        if viewModel.isLoading {
                            HStack { Spacer(); ProgressView(); Spacer() }
                                .padding()
                        }
                    }
                    .padding()
                }
                .coordinateSpace(name: "scroll")
                // Capture the ScrollView height from the outer GeometryReader
                .onAppear { scrollHeight = outerProxy.size.height }
                .onChange(of: outerProxy.size) { newSize in scrollHeight = newSize.height }
                // If videos just loaded and nothing is playing yet, start the first video immediately
                .onChange(of: viewModel.videos.count) { _ in
                    guard viewModel.currentPlayingID == nil, let first = viewModel.videos.first else { return }
                    Task {
                        await viewModel.ensurePlayback(for: first)
                        await viewModel.setPlaying(first)
                    }
                }
                // Listen for updates to all cell frames and pick the first fully-visible video to play
                .onPreferenceChange(VideoFramesKey.self) { frames in
                    // Require N% visibility of the video player's height before autoplay.
                    let requiredFraction: CGFloat = 0.8
                    // Visible rect is from y=0 to y=scrollHeight in the named scroll coordinate space
                    if let candidate = frames.first(where: { (_, frame) in
                        let visibleTop = max(frame.minY, 0)
                        let visibleBottom = min(frame.maxY, scrollHeight)
                        let visibleHeight = max(visibleBottom - visibleTop, 0)
                        let fractionVisible = (frame.height > 0) ? (visibleHeight / frame.height) : 0
                        return fractionVisible >= requiredFraction
                    }) {
                        let id = candidate.key
                        if viewModel.currentPlayingID != id {
                            if let videoToPlay = viewModel.videos.first(where: { $0.id == id }) {
                                Task {
                                    await viewModel.ensurePlayback(for: videoToPlay)
                                    await viewModel.setPlaying(videoToPlay)
                                    await viewModel.loadMoreIfNeeded(currentVideo: videoToPlay)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Videos")
            .refreshable {
                await viewModel.loadInitialVideos()
            }
            .alert((viewModel.error ?? ""), isPresented: .constant(viewModel.error != nil)) {
                Button("OK") { viewModel.error = nil }
            }
        }
    }
}

#Preview {
    ContentView()
}
