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
                            VideoPlayer(player: video.playback.player)
                                .frame(maxWidth: .infinity)
                                .aspectRatio(9.0/16.0, contentMode: .fit) // 9:16 for vertical video
                                .cornerRadius(12)

                            // show short id to help verify unique items in the list
                            Text(video.id.prefix(80))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 8)
                        .onAppear {
                            // debug print to confirm each cell's id when it appears
                            print("Appearing video id: \(video.id)")
                            Task { await viewModel.loadMoreIfNeeded(currentVideo: video) }
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
