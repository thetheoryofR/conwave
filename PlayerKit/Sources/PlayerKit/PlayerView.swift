import AVFoundation
import SwiftUI
import UIKit

/// UIViewRepresentable wrapping an AVPlayerLayer for a single AVPlayer.
public struct PlayerView: UIViewRepresentable {
    public let player:  AVPlayer
    public var gravity: AVLayerVideoGravity

    public init(player: AVPlayer, gravity: AVLayerVideoGravity = .resizeAspectFill) {
        self.player  = player
        self.gravity = gravity
    }

    public func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player       = player
        view.playerLayer.videoGravity = gravity
        view.backgroundColor = .black
        return view
    }

    public func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player       = player
        uiView.playerLayer.videoGravity = gravity
    }

    // MARK: - UIView subclass

    public final class PlayerUIView: UIView {
        public override class var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        public override func layoutSubviews() {
            super.layoutSubviews()
            playerLayer.frame = bounds
        }
    }
}
