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

            // Also add a pan gesture to dismiss keyboard on swipes/drags outside text inputs.
            let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
            pan.cancelsTouchesInView = false
            pan.delegate = context.coordinator
            window.addGestureRecognizer(pan)
            context.coordinator.panGesture = pan
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let g = coordinator.gesture, let w = coordinator.window {
            w.removeGestureRecognizer(g)
        }
        if let p = coordinator.panGesture, let w = coordinator.window {
            w.removeGestureRecognizer(p)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var gesture: UITapGestureRecognizer?
        weak var panGesture: UIPanGestureRecognizer?
        weak var window: UIWindow?

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard g.state == .ended else { return }
            guard let w = window else { return }
            let loc = g.location(in: w)
            if let hit = w.hitTest(loc, with: nil) {
                // If the touch landed in or inside a UITextView/UITextField, ignore
                if containsTextInput(hit) { return }
            }
            // Dismiss keyboard
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            // Dismiss keyboard when a pan begins outside of text inputs
            guard g.state == .began else { return }
            guard let w = window else { return }
            let loc = g.location(in: w)
            if let hit = w.hitTest(loc, with: nil) {
                if containsTextInput(hit) { return }
            }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if let view = touch.view {
                // If the touched view or any ancestor/descendant contains a text input, don't intercept
                if containsTextInput(view) { return false }
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Allow our gestures to run alongside scroll view gestures so we don't block scrolling
            return true
        }

        // Recursively check descendants and ancestors for UITextView/UITextField
        private func containsTextInput(_ view: UIView?) -> Bool {
            guard let v = view else { return false }
            if v is UITextView || v is UITextField { return true }
            // check ancestors
            var parent = v.superview
            while parent != nil {
                if parent is UITextView || parent is UITextField { return true }
                parent = parent?.superview
            }
            // check descendants
            for sub in v.subviews {
                if containsTextInput(sub) { return true }
            }
            return false
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
                HStack(alignment: .center, spacing: 12) {
                    // Input HStack: Growing text view + inline send button inside the same rounded background
                    HStack(spacing: 8) {
                        GrowingTextView(text: bindingForVideo(), placeholder: "Send message", minHeight: 36, maxLines: 5, height: $textHeight) { isEditing in
                            // Animate the UI changes when editing begins/ends
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8, blendDuration: 0)) {
                                isEditingLocal = isEditing
                            }
                            Task {
                                if isEditing {
                                    await viewModel.beginEditing()
                                } else {
                                    await viewModel.endEditing()
                                }
                            }
                        }
                        .frame(height: min(textHeight, CGFloat(5) * 24))
                        .padding(.vertical, 6)

                        // Inline send button is inside the same rounded background so it doesn't stick out
                        Button(action: {
                            bindingForVideo().wrappedValue = ""
                            isEditingLocal = false
                            Task { await viewModel.endEditing() }
#if canImport(UIKit)
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
                        }) {
                            Image(systemName: "paperplane.fill")
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Circle().fill(Color.accentColor))
                        }
                        .disabled(bindingForVideo().wrappedValue.isEmpty)
                    }
                    .padding(.horizontal, 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                    .padding(.leading, 12)
                    // Expand input to fill space when editing to hide the action icons
                    .frame(maxWidth: isEditingLocal ? .infinity : nil)
                    .animation(.easeInOut(duration: 0.22), value: isEditingLocal)

                    // Action icons to the right of the input: hide while editing
                    if !isEditingLocal {
                        HStack(spacing: 12) {
                            Button(action: {
                                // placeholder heart action
                            }) {
                                Image(systemName: "heart")
                                    .font(.title2)
                                    .padding(8)
                            }

                            Button(action: {
                                // placeholder share action
                            }) {
                                Image(systemName: "paperplane")
                                    .font(.title2)
                                    .padding(8)
                            }
                        }
                        .padding(.trailing, 12)
                        .animation(.easeInOut(duration: 0.22), value: isEditingLocal)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
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
    // Allow newline insertion (default return key behavior)
    tv.returnKeyType = .default
        tv.backgroundColor = .clear
        // Ensure the UITextView is interactive and editable
        tv.isUserInteractionEnabled = true
        tv.isSelectable = true
        tv.isEditable = true
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
        // Show the placeholder string when the bound `text` is empty and the text view is not focused.
        // Ensure the UITextView remains interactive in case SwiftUI replaces the view
        uiView.isUserInteractionEnabled = true
        uiView.isSelectable = true
        uiView.isEditable = true

        if uiView.isFirstResponder {
            // When editing, reflect the bound text directly and ensure visible text color
            if uiView.text != text {
                uiView.text = text
            }
            // Always use the label color while editing so typed characters and caret are visible
            uiView.textColor = UIColor.label
        } else {
            // Not editing: show placeholder string if there's no text
            if text.isEmpty {
                if uiView.text != placeholder {
                    uiView.text = placeholder
                }
                uiView.textColor = UIColor.placeholderText
            } else {
                if uiView.text != text {
                    uiView.text = text
                }
                uiView.textColor = UIColor.label
            }
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
            // Allow newline characters so the text view supports multi-line input.
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
