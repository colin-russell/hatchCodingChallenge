//
//  ContentView.swift
//  HatchCodingChallenge
//
//  Created by Colin Russell on 2025-10-07.
//

import SwiftUI
import AVKit
import UIKit

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
                            VideoCellView(video: video, viewModel: viewModel)
                                .background(
                                    GeometryReader { proxy in
                                        Color.clear
                                            .preference(key: VideoFramesKey.self, value: [video.id: proxy.frame(in: .named("scroll"))])
                                    }
                                )
                                .onAppear {
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
                .scrollDisabled(viewModel.isEditingText)
                .coordinateSpace(name: "scroll")
                // Capture the ScrollView height from the outer GeometryReader
                .onAppear { scrollHeight = outerProxy.size.height }
                .onChange(of: outerProxy.size) { newSize in scrollHeight = newSize.height }
                // If videos just loaded and nothing is playing yet, start the first video immediately
                .onChange(of: viewModel.videos.count) { _ in
                    guard viewModel.currentPlayingID == nil, let first = viewModel.videos.first else { return }
                    Task {
                        await viewModel.attemptSetPlayingIfReady(first)
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
                                    await viewModel.attemptSetPlayingIfReady(videoToPlay)
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

// MARK: - VideoCellView

struct VideoCellView: View {
    let video: Video
    @ObservedObject var viewModel: VideoListViewModel
    @State private var text: String = ""
    @State private var textHeight: CGFloat = 40
    @State private var isEditingLocal: Bool = false

    var body: some View {
        VStack(alignment: .leading) {
            ZStack(alignment: .bottom) {
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

                // Overlayed input at the bottom of the player (compact; won't fill whole player)
                HStack {
                    ZStack(alignment: .leading) {
                        GrowingTextView(text: bindingForVideo(), placeholder: "Send message", minHeight: 36, maxLines: 5) { isEditing in
                            // update local editing state and inform view model
                            isEditingLocal = isEditing
                            Task {
                                if isEditing {
                                    await viewModel.beginEditing()
                                } else {
                                    await viewModel.endEditing()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(10)
                        .padding(.horizontal, 12)

                        // SwiftUI overlay placeholder to ensure visibility across platforms
                        if (bindingForVideo().wrappedValue.isEmpty) && !isEditingLocal {
                            Text("Send message")
                                .foregroundColor(.secondary)
                                .padding(.leading, 24)
                        }
                    }
                }
                .padding(.bottom, 12)
            }

            // Metadata below the player (keeps the overlay uncluttered)
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
    }

    private func bindingForVideo() -> Binding<String> {
        Binding(get: {
            viewModel.inputTexts[video.id] ?? ""
        }, set: { newValue in
            viewModel.inputTexts[video.id] = newValue
        })
    }
}

// UIKit-backed GrowingTextView for iOS, fallback SwiftUI TextEditor for other platforms
#if canImport(UIKit)
struct GrowingTextView: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var minHeight: CGFloat = 36
    var maxLines: Int = 5
    var onEditingChanged: (Bool) -> Void

    init(text: Binding<String>, placeholder: String, minHeight: CGFloat = 36, maxLines: Int = 5, onEditingChanged: @escaping (Bool) -> Void) {
        self._text = text
        self.placeholder = placeholder
        self.minHeight = minHeight
        self.maxLines = maxLines
        self.onEditingChanged = onEditingChanged
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        // Always allow internal scrolling; the SwiftUI frame will keep the visible height small
        tv.isScrollEnabled = true
        // Show placeholder string when bound text is empty
        tv.text = text.isEmpty ? placeholder : text
        tv.textColor = text.isEmpty ? UIColor.placeholderText : UIColor.label
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.isEditable = true
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
            uiView.textColor = text.isEmpty ? UIColor.placeholderText : UIColor.label
        }

        // Keep visible height small; enable internal scrolling when content is larger than visible
        let visibleHeight: CGFloat = 36
        uiView.isScrollEnabled = uiView.contentSize.height > visibleHeight
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: GrowingTextView
        init(_ parent: GrowingTextView) { self.parent = parent }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if textView.textColor == UIColor.placeholderText {
                // Clear the visual placeholder but don't write it to the model
                textView.text = ""
                textView.textColor = UIColor.label
                parent.text = ""
            }
            parent.onEditingChanged(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if textView.text.isEmpty {
                textView.text = parent.placeholder
                textView.textColor = UIColor.placeholderText
                parent.text = ""
            } else {
                parent.text = textView.text
            }
            parent.onEditingChanged(false)
        }

        func textViewDidChange(_ textView: UITextView) {
            // Avoid saving the placeholder string into the bound model
            if textView.textColor == UIColor.placeholderText {
                parent.text = ""
            } else {
                parent.text = textView.text
            }
        }
    }
}
#else
struct GrowingTextView: View {
    @Binding var text: String
    var placeholder: String
    var minHeight: CGFloat = 36
    var maxLines: Int = 5
    var onEditingChanged: (Bool) -> Void

    var body: some View {
        TextEditor(text: $text)
            .frame(minHeight: minHeight, maxHeight: CGFloat(maxLines) * 24)
            .overlay(Group {
                if text.isEmpty { Text(placeholder).foregroundColor(.secondary).padding(.leading, 6).padding(.top, 8) }
            }, alignment: .topLeading)
            .onTapGesture { onEditingChanged(true) }
    }
}
#endif
