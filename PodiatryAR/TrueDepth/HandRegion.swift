//
//  HandRegion.swift
//  PodiatryAR
//
//  Created by Mann Fam on 7/5/26.
//


import Vision
import CoreVideo
import CoreGraphics

/// The result of a single hand-pose detection: a normalized bounding box
/// (Vision's coordinate space — 0...1, origin bottom-left) around the
/// detected wrist and finger joints, padded slightly to cover the skin
/// around those landmarks.
struct HandRegion {
    var boundingBox: CGRect
}

/// Finds "where the hand is" in a color frame using Vision's hand-pose
/// landmarks, so capture can crop to the hand instead of relying on depth
/// continuity (which can't tell a wrist from the forearm behind it — they're
/// the same continuous surface).
///
/// This deliberately does NOT try to build a precise hand silhouette/mask.
/// A landmark bounding box is a coarser cut than a real segmentation mask
/// would be, but it's exactly what's needed here: the wrist joint itself
/// becomes the box's lower boundary (plus a small pad for the heel of the
/// palm), so the forearm beyond it is excluded by construction, no depth
/// heuristic required.
enum HandRegionDetector {

    /// Joints used to build the bounding box. Deliberately excludes nothing
    /// below the wrist — there is nothing below the wrist that's part of
    /// the hand.
    private static let joints: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbTip, .thumbIP, .thumbMP, .thumbCMC,
        .indexTip, .indexDIP, .indexPIP, .indexMCP,
        .middleTip, .middleDIP, .middlePIP, .middleMCP,
        .ringTip, .ringDIP, .ringPIP, .ringMCP,
        .littleTip, .littleDIP, .littlePIP, .littleMCP
    ]

    private static let minimumJointConfidence: Float = 0.3
    /// Minimum number of confidently-detected joints before trusting the
    /// resulting box; too few (e.g. just a fingertip peeking into frame)
    /// produces a box that isn't representative of the whole hand.
    private static let minimumJointCount = 6

    /// Fractional padding added around the raw landmark bounding box, as a
    /// fraction of that box's own width/height. Covers the skin surrounding
    /// the landmarks (landmarks sit on joints, not on the silhouette edge)
    /// without opening the box up far enough to pull in the forearm.
    private static let paddingFraction: CGFloat = 0.22

    /// - Parameter orientation: The orientation Vision should interpret the
    ///   pixel buffer's contents with. `TrueDepthCaptureManager` rotates both
    ///   its video and depth connections to `.portrait` before delivery, so
    ///   the buffer's rows/columns are already right-side-up portrait and
    ///   `.up` is correct here. If hand detection performs poorly on device,
    ///   this is the first thing to double check against how the buffer is
    ///   actually laid out in memory.
    static func detectHandRegion(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up) -> HandRegion? {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first,
              let allPoints = try? observation.recognizedPoints(.all) else {
            return nil
        }

        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        var confidentCount = 0

        for joint in joints {
            guard let point = allPoints[joint], point.confidence >= minimumJointConfidence else { continue }
            confidentCount += 1
            minX = min(minX, point.location.x)
            maxX = max(maxX, point.location.x)
            minY = min(minY, point.location.y)
            maxY = max(maxY, point.location.y)
        }

        guard confidentCount >= minimumJointCount, minX <= maxX, minY <= maxY else { return nil }

        let width = maxX - minX
        let height = maxY - minY
        let padX = max(width * paddingFraction, 0.01)
        let padY = max(height * paddingFraction, 0.01)

        minX = max(0, minX - padX)
        minY = max(0, minY - padY)
        maxX = min(1, maxX + padX)
        maxY = min(1, maxY + padY)

        return HandRegion(boundingBox: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }
}