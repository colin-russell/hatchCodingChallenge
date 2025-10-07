//
//  ContentView.swift
//  HatchCodingChallenge
//
//  Created by Colin Russell on 2025-10-07.
//

import SwiftUI
import AVKit

struct ContentView: View {
    @State private var viewModel = VideoListViewModel()
    
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(viewModel.videos, id: \.id) { video in
                        VStack(alignment: .leading) {
                            if let playback = video.playback {
                                VideoPlayer(player: playback.player)
                                    .frame(maxWidth: .infinity)
                                    .aspectRatio(9.0/16.0, contentMode: .fit) // 9:16 for vertical video
                                    .cornerRadius(12)
                            } else {
                                // Placeholder while we lazily create AV resources
                                ZStack {
                                    Rectangle()
                                        .fill(Color.black.opacity(0.1))
                                        .aspectRatio(9.0/16.0, contentMode: .fit)
                                        .cornerRadius(12)
                                    ProgressView()
                                }
                                .frame(maxWidth: .infinity)
                            }

                            // show short id to help verify unique items in the list
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
                        .onAppear {
                            Task {
                                print("Appearing video id: \(video.id)")
                                // Ensure playback exists before trying to play
                                await viewModel.ensurePlayback(for: video)
                                await viewModel.setPlaying(video)
                                await viewModel.loadMoreIfNeeded(currentVideo: video)
                            }
                        }
                        .onDisappear {
                            Task {
                                // Cleanup playback when cell disappears to free AV resources
                                await viewModel.cleanupPlayback(for: video)
                            }
                        }
                    }
                    if viewModel.isLoading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .padding()
                    }
                }
                .padding()
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
