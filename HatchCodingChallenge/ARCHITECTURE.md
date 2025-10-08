# HatchCodingChallenge – Architecture & Design Overview

## Overview
This project implements a vertically scrolling feed of short videos with lightweight inline interaction (a compact message input and simple actions) and automatic playback management.

We focus on:
- A SwiftUI-first UI, with UIKit interop where it clearly improves UX (growing text input, global keyboard dismiss).
- A view model that orchestrates data loading, playback lifecycle, paging, and editing state.
- Efficient, viewport-driven playback selection without heavy observers.

The goal is a smooth, TikTok/Reels-style experience that avoids jank by preloading just-in-time, deferring heavy work, and updating only what’s visible.

## Architecture Approach
- **SwiftUI Views**
  - `ContentView`: Owns the scrolling feed, visibility tracking, refresh, and error presentation. It uses a named coordinate space plus a `PreferenceKey` to compute which cell is most visible. We intentionally removed `.scrollTargetBehavior(.viewAligned)` to avoid snapping that conflicted with visibility-driven autoplay.
  - `VideoCellView`: Renders a single video cell. Shows an active `VideoPlayer` (AVKit) or a loading placeholder, plus a compact input bar overlaid on the video with a growing text view.
- **View Model (MVVM)**
  - `VideoListViewModel` (ObservableObject) is the source of truth for:
    - `videos`: Array of `Video` models, each with an id and optional `playback` handle.
    - Playback lifecycle: `ensurePlayback(for:)`, `cleanupPlayback(for:)`, `attemptSetPlayingIfReady(_:)`, `currentPlayingID`.
    - Paging: `loadMoreIfNeeded(currentVideo:)`.
    - Editing state: `isEditingText`, `beginEditing()`, `endEditing()` to adjust scrolling/gestures while typing.
    - Error & refresh: `error`, `loadInitialVideos()`.
- **Models**
  - `Video`: Lightweight model with `id`, metadata, and an optional `playback` container that holds an `AVPlayer` and error state.
  - `Playback`: Small wrapper for `AVPlayer` plus transient state (ready/error).
- **UIKit Interop**
  - `GrowingTextView` (UIViewRepresentable): A UIKit-backed `UITextView` that auto-grows up to a max line count, reporting height updates to SwiftUI.
  - `GlobalTapDismiss`: Installs safe window-level gestures to dismiss the keyboard on taps/drags outside text inputs without interfering with scroll gestures.

## Key Design Decisions & Trade-offs
1. **SwiftUI + AVKit for Player**
   - Decision: Use `VideoPlayer` instead of a custom `AVPlayerLayer` host.
   - Trade-off: `VideoPlayer` is simpler and integrates well with SwiftUI but offers fewer customization hooks. For auto-play with a light overlay, simplicity wins.

2. **Visibility-Driven Playback via PreferenceKey**
   - Decision: Compute visibility fractions per cell using a named coordinate space and a custom `PreferenceKey`.
   - Trade-off: Keeps state localized and avoids heavy scroll offset observers. Geometry work is limited to visible cells via `LazyVStack`.

3. **Inline, Overlay Input with UIKit Growing TextView**
   - Decision: Use a UIKit `UITextView` for predictable auto-grow behavior and editing.
   - Trade-off: A pure SwiftUI `TextEditor` is simpler but less precise for growth and can jitter layouts. UIKit interop yields better UX with minimal bridging code.

4. **Global Keyboard Dismissal via Window Gestures**
   - Decision: Install tap and pan recognizers at the window level to dismiss the keyboard when interacting outside text inputs.
   - Trade-off: Must avoid blocking scroll. We set `cancelsTouchesInView = false`, allow simultaneous recognition, and ignore touches inside text inputs.

5. **Conservative Autoplay Threshold**
   - Decision: Require ≥40% visibility before promoting a cell to “playing.”
   - Trade-off: Slightly later start when a cell first enters view, but far less thrash during fast scrolls.

6. **Deferred Preloading & Paging**
   - Decision: Preload playback when a cell appears and opportunistically as a candidate becomes dominant; check `loadMoreIfNeeded` as we approach the end.
   - Trade-off: Saves memory and network vs. blanket preloads, with a small first-play delay mitigated by early `ensurePlayback(for:)`.

## Memory Management Strategy
- **Player Lifecycle**
  - Each `Video` holds an optional `playback`. We create it on-demand (`ensurePlayback`) and tear it down when a cell disappears (`cleanupPlayback`) or once another item becomes the main player. Only one `currentPlayingID` is active at a time.
- **Avoiding Retain Cycles**
  - Asynchronous tasks (`Task { await ... }`) don’t capture views strongly. The view model owns long-lived state; cells pass identifiers to avoid closures retaining player resources.
- **Lightweight Models**
  - `Video` and `Playback` remain minimal. Heavy assets (player items, buffers) are encapsulated and short-lived.
- **UIKit Bridges**
  - `GrowingTextView` communicates via bindings and a coordinator; it doesn’t retain the SwiftUI view. `GlobalTapDismiss` stores gestures weakly and removes them in `dismantleUIView`.

## Smooth Scrolling & Transition Strategy
- **Visibility Thresholding**
  - Autoplay switches only when a candidate exceeds the 40% threshold. For example, once the second video crosses ~40% visibility, we promote it and pause the previous one.
- **Geometry Scoped to Visible Cells**
  - `LazyVStack` keeps geometry work bounded to what’s on-screen, maintaining smoothness.
- **Non-blocking Keyboard Dismissal**
  - Window-level gestures recognize alongside scroll views and don’t cancel touches, so scroll stays fluid while taps/drags outside inputs dismiss the keyboard.
- **Editing State Disables Scroll**
  - While typing, `scrollDisabled(isEditingText)` prevents accidental scroll jumps and layout shifts. The input expands with subtle spring/ease animations.
- **Prefetch & Paging**
  - As a cell becomes the dominant candidate, the view model attempts to start playback and checks if more data should be loaded, so you don’t “hit the end” abruptly.

## Error Handling & Resilience
- **Per-Cell Error UI**
  - If playback fails, the cell shows a compact banner with a retry button, keeping issues localized.
- **Global Alert for Data Errors**
  - A top-level `alert` surfaces data load errors; it’s dismissible so the user can continue.

## Extensibility
- **Custom Player Controls**
  - If deeper control is needed, swap `VideoPlayer` for a custom `UIViewRepresentable` hosting `AVPlayerLayer` while keeping the same view model APIs.
- **Smarter Preloading**
  - Add a small prefetch window (e.g., next 1–2 items) based on scroll direction if analytics show frequent immediate plays.
- **Haptics & Transitions**
  - Add subtle haptics on play/pause or input expansion; consider matched-geometry effects if the design calls for it.
