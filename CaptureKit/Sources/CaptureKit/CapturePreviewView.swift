import AVFoundation
import SwiftUI
import UIKit

/// UIViewRepresentable that hosts an AVCaptureVideoPreviewLayer.
///
/// Usage:
///   CapturePreviewView(previewLayer: session.previewLayer)
///       .ignoresSafeArea()
public struct CapturePreviewView: UIViewRepresentable {
    public let previewLayer: AVCaptureVideoPreviewLayer

    public init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
    }

    public func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        return view
    }

    public func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.attach(previewLayer)
    }

    // MARK: - UIView subclass

    public final class PreviewUIView: UIView {
        private weak var currentLayer: AVCaptureVideoPreviewLayer?

        func attach(_ layer: AVCaptureVideoPreviewLayer) {
            guard layer !== currentLayer else { return }
            currentLayer?.removeFromSuperlayer()
            layer.frame = bounds
            self.layer.addSublayer(layer)
            currentLayer = layer
        }

        public override func layoutSubviews() {
            super.layoutSubviews()
            currentLayer?.frame = bounds
        }
    }
}
