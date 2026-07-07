//
//  CameraPreviewView.swift
//  PodiatryAR
//
//  Created by Mann Fam on 7/5/26.
//


import SwiftUI
import AVFoundation
import CoreGraphics
import simd

/// One "live" unprojected depth frame, plus everything needed to project its
/// points back onto the 2D video feed they came from.
struct LiveOverlaySnapshot {
    var points: [SIMD3<Float>]
    var intrinsics: matrix_float3x3
    var depthWidth: Int
    var depthHeight: Int
}

/// Full-screen live preview of the TrueDepth camera feed, with an optional
/// live point-cloud overlay drawn directly on top of the subject — the same
/// idea as ARKit's own point-cloud visualization.
///
/// The overlay is genuinely tracking, not decorative: every point in
/// `overlay.points` is the current frame's own depth data, re-projected
/// through the exact inverse of the pinhole model `PointCloudUnprojector`
/// used to unproject it (see the comment on `render(overlay:)` below for the
/// coordinate-space details). Because it's re-derived from that same frame's
/// depth map every time, it lands on the real object and moves with it with
/// zero drift — there's no pose-tracking or accumulated error involved, unlike
/// trying to overlay the merged/reconstructed cloud from past frames would.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var overlay: LiveOverlaySnapshot?
    /// Live "how much of the hand has been captured so far" wash — see
    /// `CoverageOverlaySnapshot` and `FrontSurfaceCapture.coverageSnapshot()`.
    /// Optional so callers outside the scanning flow don't need to think
    /// about it.
    var coverage: CoverageOverlaySnapshot?

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.render(overlay: overlay)
        uiView.render(coverage: coverage)
    }

    final class PreviewContainerView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        private let overlayLayer: CAShapeLayer = {
            let shape = CAShapeLayer()
            shape.fillColor = UIColor.clear.cgColor
            shape.strokeColor = UIColor.systemGreen.withAlphaComponent(0.9).cgColor
            shape.lineWidth = 2.2
            return shape
        }()

        /// Paints the live scan-coverage wash (yellow -> white) directly onto
        /// the hand. Added *below* `overlayLayer` so the green tracking dots
        /// still render on top of it.
        private let coverageLayer: CALayer = {
            let layer = CALayer()
            layer.contentsGravity = .resize
            return layer
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.addSublayer(coverageLayer)
            layer.addSublayer(overlayLayer)
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            layer.addSublayer(coverageLayer)
            layer.addSublayer(overlayLayer)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            overlayLayer.frame = bounds
        }

        /// Projects each 3D point back to the 2D pixel it was unprojected
        /// from, then maps that pixel onto this view exactly the way
        /// `.resizeAspectFill` maps the video image onto it, so the dots
        /// land on the real object instead of in a disconnected box.
        ///
        /// Two things this deliberately does NOT rely on:
        /// - AVFoundation's `layerPointConverted(fromCaptureDevicePoint:)`,
        ///   whose device-coordinate space is defined relative to the
        ///   sensor's native orientation, not the `.portrait` rotation this
        ///   session's connections are configured with — using it here would
        ///   silently reintroduce an orientation mismatch.
        /// - Any assumption that the depth output's mirroring matches the
        ///   video preview's mirroring; they're independent connections, so
        ///   this reads the preview layer's own mirroring state directly.
        func render(overlay: LiveOverlaySnapshot?) {
            guard let overlay, !overlay.points.isEmpty, bounds.width > 0, bounds.height > 0 else {
                overlayLayer.path = nil
                return
            }

            let fx = overlay.intrinsics.columns.0.x
            let fy = overlay.intrinsics.columns.1.y
            let cx = overlay.intrinsics.columns.2.x
            let cy = overlay.intrinsics.columns.2.y
            let depthWidth = Float(overlay.depthWidth)
            let depthHeight = Float(overlay.depthHeight)
            guard depthWidth > 0, depthHeight > 0 else {
                overlayLayer.path = nil
                return
            }

            let viewWidth = Float(bounds.width)
            let viewHeight = Float(bounds.height)
            // Replicates `.resizeAspectFill`: uniform scale-to-cover, centered crop.
            let scale = max(viewWidth / depthWidth, viewHeight / depthHeight)
            let offsetX = (viewWidth - depthWidth * scale) / 2
            let offsetY = (viewHeight - depthHeight * scale) / 2

            // Front camera preview is mirrored by default. If the overlay
            // ever looks flipped relative to the visible hand/foot on a real
            // device, it's this flag that needs inverting, not the math above.
            let mirrored = previewLayer.connection?.isVideoMirrored ?? true

            // Drawing every point (the depth map can carry tens of thousands)
            // would be denser than useful and a real per-frame cost; a few
            // hundred dots reads clearly as "the object is being tracked".
            let targetDotCount = 350
            let stride = max(1, overlay.points.count / targetDotCount)
            let dotRadius: CGFloat = 1.8

            let path = UIBezierPath()
            var index = 0
            for p in overlay.points {
                defer { index += 1 }
                guard index % stride == 0 else { continue }

                // Undo PointCloudUnprojector's (x, -y, -z) convention to get
                // back to raw camera-space coordinates the intrinsics expect.
                let x = p.x
                let y = -p.y
                let z = -p.z
                guard z > 0.01 else { continue }

                let u = (x * fx / z) + cx
                let v = (y * fy / z) + cy
                guard u.isFinite, v.isFinite else { continue }

                var screenX = u * scale + offsetX
                let screenY = v * scale + offsetY
                if mirrored {
                    screenX = viewWidth - screenX
                }

                let screenPoint = CGPoint(x: CGFloat(screenX), y: CGFloat(screenY))
                path.move(to: CGPoint(x: screenPoint.x + dotRadius, y: screenPoint.y))
                path.addArc(withCenter: screenPoint, radius: dotRadius, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            }
            overlayLayer.path = path.cgPath
        }

        /// Paints `coverage`'s grid as a small bitmap (one pixel per grid
        /// cell) and stretches it over exactly the same screen rect the
        /// depth grid itself occupies under `.resizeAspectFill` — the same
        /// scale/offset math `render(overlay:)` uses per-point above, just
        /// applied once to a rect instead of per dot, since this is a
        /// continuous wash rather than discrete tracked points.
        ///
        /// Mirroring is handled with a layer transform (flip about the
        /// layer's own center) rather than flipping coordinates while
        /// building the bitmap, since the source grid has a fixed
        /// (unmirrored) orientation coming out of `FrontSurfaceCapture` — see
        /// `TrueDepthCaptureManager`'s note on why the depth/video
        /// connections are pinned to a known, identical mirroring state.
        func render(coverage: CoverageOverlaySnapshot?) {
            guard let coverage, coverage.gridWidth > 0, coverage.gridHeight > 0,
                  bounds.width > 0, bounds.height > 0 else {
                coverageLayer.contents = nil
                return
            }

            let gw = coverage.gridWidth
            let gh = coverage.gridHeight
            var pixels = [UInt8](repeating: 0, count: gw * gh * 4)
            for i in 0..<(gw * gh) {
                let c = coverage.coverage[i]
                guard c >= 0 else { continue } // never sampled: fully transparent
                let t = min(1, max(0, c))
                let offset = i * 4
                pixels[offset] = 255                                  // R: solid yellow -> white
                pixels[offset + 1] = UInt8(215 + t * (255 - 215))     // G: 215 -> 255
                pixels[offset + 2] = UInt8(t * 255)                   // B: 0 -> 255
                pixels[offset + 3] = 150                               // constant translucency
            }

            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let cgImage = CGImage(width: gw,
                                        height: gh,
                                        bitsPerComponent: 8,
                                        bitsPerPixel: 32,
                                        bytesPerRow: gw * 4,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                        provider: provider,
                                        decode: nil,
                                        shouldInterpolate: true,
                                        intent: .defaultIntent) else {
                coverageLayer.contents = nil
                return
            }

            let viewWidth = Float(bounds.width)
            let viewHeight = Float(bounds.height)
            let depthWidth = Float(gw)
            let depthHeight = Float(gh)
            let scale = max(viewWidth / depthWidth, viewHeight / depthHeight)
            let offsetX = (viewWidth - depthWidth * scale) / 2
            let offsetY = (viewHeight - depthHeight * scale) / 2
            let mirrored = previewLayer.connection?.isVideoMirrored ?? true

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // `.frame` is only well-defined under an identity transform, so
            // reset it before setting frame, then apply mirroring after —
            // otherwise CALayer derives the wrong `.position` from a `.frame`
            // assignment made while already flipped.
            coverageLayer.transform = CATransform3DIdentity
            coverageLayer.frame = CGRect(x: CGFloat(offsetX), y: CGFloat(offsetY),
                                          width: CGFloat(depthWidth * scale), height: CGFloat(depthHeight * scale))
            coverageLayer.transform = mirrored ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
            coverageLayer.contents = cgImage
            CATransaction.commit()
        }
    }
}
