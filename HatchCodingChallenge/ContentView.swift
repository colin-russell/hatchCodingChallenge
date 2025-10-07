//
//  ContentView.swift
//  HatchCodingChallenge
//
//  Created by Colin Russell on 2025-10-07.
//

import SwiftUI
import AVKit
#if canImport(UIKit)
import UIKit
#endif
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
            #if canImport(UIKit)
            .background(GlobalTapDismiss())
            #endif
            .refreshable {
                await viewModel.loadInitialVideos()
            }
            .alert((viewModel.error ?? ""), isPresented: .constant(viewModel.error != nil)) {
                Button("OK") { viewModel.error = nil }
            }
        }
    }
}

#if canImport(UIKit)
// Installs a window-level tap recognizer that dismisses the keyboard for taps
// outside of text inputs (UITextView/UITextField). This avoids blocking
// other controls because the recognizer is attached directly to the keyWindow
// and uses a delegate to ignore taps inside text inputs.
struct GlobalTapDismiss: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        DispatchQueue.main.async {
            guard context.coordinator.window == nil else { return }
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = windowScene.windows.first(where: { $0.isKeyWindow }) else { return }

            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = context.coordinator
            window.addGestureRecognizer(tap)
            context.coordinator.gesture = tap
            context.coordinator.window = window
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let g = coordinator.gesture, let w = coordinator.window {
            w.removeGestureRecognizer(g)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var gesture: UITapGestureRecognizer?
        weak var window: UIWindow?

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard g.state == .ended else { return }
            guard let w = window else { return }
            let loc = g.location(in: w)
            if let hit = w.hitTest(loc, with: nil) {
                // If the touch landed in a UITextView/UITextField (or their descendants), ignore
                if hit is UITextView || hit is UITextField { return }
                var parent = hit.superview
                while parent != nil {
                    if parent is UITextView || parent is UITextField { return }
                    parent = parent?.superview
                }
            }
            // Dismiss keyboard
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if let view = touch.view {
                if view is UITextView || view is UITextField { return false }
                var parent = view.superview
                while parent != nil {
                    if parent is UITextView || parent is UITextField { return false }
                    parent = parent?.superview
                }
            }
            return true
        }
    }
}
#endif

#Preview {
    ContentView()
}

// MARK: - VideoCellView

struct VideoCellView: View {
    let video: Video
    @ObservedObject var viewModel: VideoListViewModel
    // Optional tap handler invoked when the player is tapped
    var onTap: (() -> Void)? = nil
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
                        .onTapGesture {
                            onTap?()
                        }
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
                        GrowingTextView(text: bindingForVideo(), placeholder: "Send message", minHeight: 36, maxLines: 5, height: $textHeight) { isEditing in
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
                        .frame(height: min(textHeight, CGFloat(5) * 24))
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
    @Binding var height: CGFloat

    init(text: Binding<String>, placeholder: String, minHeight: CGFloat = 36, maxLines: Int = 5, height: Binding<CGFloat>, onEditingChanged: @escaping (Bool) -> Void) {
        self._text = text
        self.placeholder = placeholder
        self.minHeight = minHeight
        self.maxLines = maxLines
        self._height = height
        self.onEditingChanged = onEditingChanged
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isScrollEnabled = false
        tv.text = text.isEmpty ? placeholder : text
        tv.textColor = text.isEmpty ? UIColor.placeholderText : UIColor.label
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.delegate = context.coordinator
        tv.returnKeyType = .done
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.isEditable = true

        // initial height
        DispatchQueue.main.async {
            let h = max(minHeight, tv.contentSize.height)
            self.height = min(h, CGFloat(maxLines) * (tv.font?.lineHeight ?? 20) + tv.textContainerInset.top + tv.textContainerInset.bottom)
        }

        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
            uiView.textColor = text.isEmpty ? UIColor.placeholderText : UIColor.label
        }

        let lineHeight = uiView.font?.lineHeight ?? 20
        let maxHeight = lineHeight * CGFloat(maxLines) + uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let contentHeight = uiView.contentSize.height
        uiView.isScrollEnabled = contentHeight > maxHeight
        let newHeight = max(minHeight, min(contentHeight, maxHeight))
        DispatchQueue.main.async {
            self.height = newHeight
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: GrowingTextView
        init(_ parent: GrowingTextView) { self.parent = parent }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Treat newline/Return as Done: dismiss keyboard and end editing
            if text == "\n" {
                textView.resignFirstResponder()
                parent.onEditingChanged(false)
                return false
            }
            // compute resulting text
            if let current = textView.text as NSString? {
                let newText = current.replacingCharacters(in: range, with: text)
                let lines = newText.components(separatedBy: CharacterSet.newlines)
                if lines.count > parent.maxLines {
                    return false
                }
            }
            return true
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if textView.textColor == UIColor.placeholderText {
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
            if textView.textColor == UIColor.placeholderText {
                parent.text = ""
            } else {
                parent.text = textView.text
            }
            let lineHeight = textView.font?.lineHeight ?? 20
            let maxHeight = lineHeight * CGFloat(parent.maxLines) + textView.textContainerInset.top + textView.textContainerInset.bottom
            let contentHeight = textView.contentSize.height
            DispatchQueue.main.async {
                self.parent.height = max(self.parent.minHeight, min(contentHeight, maxHeight))
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
    @Binding var height: CGFloat
    var onEditingChanged: (Bool) -> Void

    var body: some View {
        TextEditor(text: $text)
            .frame(minHeight: minHeight, maxHeight: height)
            .overlay(Group {
                if text.isEmpty { Text(placeholder).foregroundColor(.secondary).padding(.leading, 6).padding(.top, 8) }
            }, alignment: .topLeading)
            .onTapGesture { onEditingChanged(true) }
    }
}
#endif
