import AVFoundation
import AppKit
import SwiftUI

/// Displays the picture from an `AVPlayer` (the muted, clock-slaved video
/// player owned by `AudioPlayer`). Audio always comes from `AVAudioEngine`, so
/// this view is purely the video image; it carries no controls of its own.
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.player = player
    }

    /// A layer-backed view that hosts an `AVPlayerLayer` sized to fill it,
    /// letterboxing the video to preserve its aspect ratio.
    final class PlayerLayerView: NSView {
        private let playerLayer = AVPlayerLayer()

        var player: AVPlayer? {
            get { playerLayer.player }
            set { playerLayer.player = newValue }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
            layer?.backgroundColor = NSColor.black.cgColor
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }
}
