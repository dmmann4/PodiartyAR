import CoreVideo
import CoreGraphics
import simd
import Foundation

struct PointCloudFrame {
    var points: [SIMD3<Float>]
}

enum PointCloudUnprojector {

    /// Converts a depth map into a 3D point cloud using pinhole camera intrinsics.
    ///
    /// Rather than just keeping every pixel inside [minDepth, maxDepth] (which
    /// happily includes background clutter — walls, tables, your other hand —
    /// that lands in the same depth window as the subject), this segments the
    /// depth map first: starting from the single closest pixel in the frame,
    /// it flood-fills outward across neighboring pixels whose depth changes
    /// smoothly, which isolates the one continuous surface nearest the
    /// camera. That's what makes this shape-agnostic — a hand, a foot, or any
    /// other handheld object gets detected as "the subject" the same way,
    /// with no per-shape tuning, and disconnected background is dropped even
    /// when it falls inside the depth window.
    ///
    /// - Parameters:
    ///   - stride: Sample every Nth pixel to control point density/perf.
    ///   - minDepth/maxDepth: Absolute clip range in meters — a coarse safety
    ///     bound, not the primary way the subject is isolated anymore.
    ///   - depthContinuityThreshold: Max depth jump (meters) between
    ///     neighboring sampled pixels for them to be considered part of the
    ///     same surface. Smaller = stricter segmentation (good for separating
    ///     fingers/toes from each other); too small will fragment the subject
    ///     into disconnected pieces.
    static func unproject(depthMap: CVPixelBuffer,
                          intrinsics: matrix_float3x3,
                          strideVal: Int = 2,
                          minDepth: Float = 0.10,
                          maxDepth: Float = 0.80,
                          depthContinuityThreshold: Float = 0.015) -> PointCloudFrame {

        guard let grid = sampleDepthGrid(depthMap: depthMap, strideVal: strideVal, minDepth: minDepth, maxDepth: maxDepth) else {
            return PointCloudFrame(points: [])
        }

        return segmentAndUnproject(depthGrid: grid.values,
                                    gridWidth: grid.width,
                                    gridHeight: grid.height,
                                    strideVal: strideVal,
                                    intrinsics: intrinsics,
                                    depthContinuityThreshold: depthContinuityThreshold).frame
    }

    /// Samples a `CVPixelBuffer` depth map onto a coarser (u,v)-indexed grid.
    /// Factored out so both a single live frame (`unproject`) and a
    /// multi-frame temporal average (`FrontSurfaceCapture`) can build the
    /// same shape of grid before handing it to `segmentAndUnproject`.
    static func sampleDepthGrid(depthMap: CVPixelBuffer,
                                 strideVal: Int,
                                 minDepth: Float,
                                 maxDepth: Float) -> (values: [Float], width: Int, height: Int)? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

        let gridWidth = (width + strideVal - 1) / strideVal
        let gridHeight = (height + strideVal - 1) / strideVal
        var depthGrid = [Float](repeating: .nan, count: gridWidth * gridHeight)

        for gv in 0..<gridHeight {
            let v = gv * strideVal
            guard v < height else { continue }
            let rowPtr = baseAddress.advanced(by: v * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for gu in 0..<gridWidth {
                let u = gu * strideVal
                guard u < width else { continue }
                let z = rowPtr[u]
                guard z.isFinite, z >= minDepth, z <= maxDepth else { continue }
                depthGrid[gv * gridWidth + gu] = z
            }
        }

        return (depthGrid, gridWidth, gridHeight)
    }

    /// The "detect the subject" step, factored out of `unproject` so it can
    /// run once against an already-averaged depth grid (the fast, single-
    /// viewpoint capture path) instead of only ever against one raw frame.
    ///
    /// Finds the single closest valid sample, flood-fills outward across
    /// neighboring grid cells whose depth changes smoothly to isolate the
    /// one continuous surface nearest the camera, then unprojects just that
    /// surface (or the full grid, if segmentation implausibly found almost
    /// nothing) into camera-space points.
    static func segmentAndUnproject(depthGrid: [Float],
                                     gridWidth: Int,
                                     gridHeight: Int,
                                     strideVal: Int,
                                     intrinsics: matrix_float3x3,
                                     depthContinuityThreshold: Float = 0.015) -> (frame: PointCloudFrame, keepSet: Set<Int>?) {
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y

        var nearestValue: Float = .greatestFiniteMagnitude
        var nearestIndex = -1
        for (idx, z) in depthGrid.enumerated() where z.isFinite && z < nearestValue {
            nearestValue = z
            nearestIndex = idx
        }

        guard nearestIndex >= 0 else { return (PointCloudFrame(points: []), nil) }

        var visited = [Bool](repeating: false, count: depthGrid.count)
        var stack = [nearestIndex]
        visited[nearestIndex] = true
        var foregroundIndices: [Int] = []
        foregroundIndices.reserveCapacity(depthGrid.count / 4)

        while let idx = stack.popLast() {
            foregroundIndices.append(idx)
            let gv = idx / gridWidth
            let gu = idx % gridWidth
            let z = depthGrid[idx]

            for (nu, nv) in [(gu - 1, gv), (gu + 1, gv), (gu, gv - 1), (gu, gv + 1)] {
                guard nu >= 0, nu < gridWidth, nv >= 0, nv < gridHeight else { continue }
                let nIdx = nv * gridWidth + nu
                guard !visited[nIdx] else { continue }
                let nz = depthGrid[nIdx]
                guard nz.isFinite, abs(nz - z) <= depthContinuityThreshold else { continue }
                visited[nIdx] = true
                stack.append(nIdx)
            }
        }

        // If segmentation somehow found an implausibly tiny surface (e.g. a
        // single stray noisy pixel was the "nearest" point), fall back to the
        // full depth window rather than returning an almost-empty frame.
        let useSegmentation = foregroundIndices.count >= max(200, depthGrid.count / 50)
        let keepSet: Set<Int>? = useSegmentation ? Set(foregroundIndices) : nil

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(useSegmentation ? foregroundIndices.count : depthGrid.count)

        for gv in 0..<gridHeight {
            for gu in 0..<gridWidth {
                let idx = gv * gridWidth + gu
                let z = depthGrid[idx]
                guard z.isFinite else { continue }
                if let keepSet, !keepSet.contains(idx) { continue }

                let u = Float(gu * strideVal)
                let v = Float(gv * strideVal)
                let x = (u - cx) * z / fx
                let y = (v - cy) * z / fy
                points.append(SIMD3<Float>(x, -y, -z))
            }
        }

        return (PointCloudFrame(points: points), keepSet)
    }
}

/// Fast, single-viewpoint capture — this is the path that mimics "hold the
/// phone still for a moment and get back the surface facing the lens",
/// instead of `PointCloudAccumulator`'s walk-around-and-ICP-stitch approach
/// below.
///
/// Because the phone isn't moving during this capture, there's no rigid
/// transform to solve for between frames: the same pixel in consecutive
/// depth frames already corresponds to the same physical point, so frames
/// can be folded together with a plain per-pixel running average. That
/// average fights the TrueDepth sensor's per-frame noise without needing
/// ICP at all, and it finishes as soon as a handful of frames have landed —
/// typically well under a second — rather than needing a sweep around the
/// object.
actor FrontSurfaceCapture {
    private var depthSum: [Float] = []
    private var sampleCounts: [Int32] = []
    /// Per-cell running sum of sampled color (RGB, 0...1), parallel to
    /// `depthSum`/`sampleCounts`. Folded in from the same color frame the
    /// hand-region crop already uses, so the averaged result is a genuine
    /// photo of the scanned skin, not a synthetic material — see
    /// `ModelExporter.makeSCNGeometry`, which renders it as vertex color.
    private var colorSum: [SIMD3<Float>] = []
    private var gridWidth = 0
    private var gridHeight = 0
    private var latestIntrinsics: matrix_float3x3?
    private let strideVal: Int
    private let minDepth: Float
    private let maxDepth: Float

    private(set) var framesAccumulated = 0

    // strideVal: 1 == full sensor resolution. This used to default to 2
    // (every other pixel, in both dimensions — a 4x reduction in point
    // count before the data ever reaches the mesher), which was the single
    // biggest contributor to the coarse/blurry output: no amount of
    // downstream smoothing can put detail back that was thrown away here.
    // Full res costs more per-frame work in `accumulate` and a larger grid
    // for `FrontSurfaceMesher` to triangulate, but the capture window is
    // short (~1.2s) and modern TrueDepth-capable devices have margin for it.
    init(strideVal: Int = 1, minDepth: Float = 0.10, maxDepth: Float = 0.80) {
        self.strideVal = strideVal
        self.minDepth = minDepth
        self.maxDepth = maxDepth
    }

    func reset() {
        depthSum = []
        sampleCounts = []
        colorSum = []
        gridWidth = 0
        gridHeight = 0
        latestIntrinsics = nil
        framesAccumulated = 0
    }

    /// Folds one raw depth frame into the running per-pixel average,
    /// restricted to `handRegion` — a normalized (0...1, origin bottom-left,
    /// matching `VNDetectHumanHandPoseRequest`'s coordinate space) bounding
    /// box around that frame's detected wrist + finger joints.
    ///
    /// This is the actual fix for "forearm ends up in the scan": the old
    /// flood-fill segmentation in `PointCloudUnprojector` isolates the
    /// nearest *continuous surface*, and the forearm is physically part of
    /// that same surface, so it never got cut. Cropping to Vision's hand
    /// landmarks *before* a sample is ever summed means forearm depth
    /// samples are never folded into the average in the first place — the
    /// wrist landmark itself is the boundary, not a depth heuristic.
    ///
    /// If a given frame's hand region can't be established, the whole frame
    /// is dropped rather than folded in uncropped: one lost frame out of the
    /// averaging window is harmless, but even a single uncropped frame would
    /// reintroduce forearm samples into the average.
    /// - Parameter colorBuffer: The same-frame color buffer the hand region
    ///   was detected in. `TrueDepthCaptureManager` pins both the video and
    ///   depth connections to identical orientation + (non-)mirroring, which
    ///   is exactly what makes a normalized (x, y) coordinate mean the same
    ///   physical point in both buffers — see the comment there. That's what
    ///   lets this sample a color for each depth cell with no separate
    ///   calibration step: reuse the depth cell's own normalized position
    ///   directly as a lookup into the color buffer.
    func accumulate(depthMap: CVPixelBuffer, colorBuffer: CVPixelBuffer?, intrinsics: matrix_float3x3, handRegion: CGRect) {
        guard let grid = PointCloudUnprojector.sampleDepthGrid(depthMap: depthMap,
                                                                strideVal: strideVal,
                                                                minDepth: minDepth,
                                                                maxDepth: maxDepth) else { return }

        if gridWidth != grid.width || gridHeight != grid.height {
            gridWidth = grid.width
            gridHeight = grid.height
            depthSum = [Float](repeating: 0, count: grid.width * grid.height)
            sampleCounts = [Int32](repeating: 0, count: grid.width * grid.height)
            colorSum = [SIMD3<Float>](repeating: .zero, count: grid.width * grid.height)
        }

        let widthDenominator = Float(max(gridWidth - 1, 1))
        let heightDenominator = Float(max(gridHeight - 1, 1))

        // Lock once per frame (not per pixel) and read raw BGRA bytes directly,
        // matching the pixel format TrueDepthCaptureManager's videoDataOutput
        // requests (kCVPixelFormatType_32BGRA).
        var colorPlane: (base: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int)?
        if let colorBuffer {
            CVPixelBufferLockBaseAddress(colorBuffer, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(colorBuffer) {
                colorPlane = (base, CVPixelBufferGetWidth(colorBuffer), CVPixelBufferGetHeight(colorBuffer), CVPixelBufferGetBytesPerRow(colorBuffer))
            }
        }
        defer { if let colorBuffer { CVPixelBufferUnlockBaseAddress(colorBuffer, .readOnly) } }

        for gv in 0..<gridHeight {
            // Depth grid row 0 is the top of the image; Vision's normalized
            // space has y=0 at the bottom, so this flips row -> normalized-y.
            let normalizedY = Float(1) - (Float(gv) / heightDenominator)
            for gu in 0..<gridWidth {
                let idx = gv * gridWidth + gu
                let z = grid.values[idx]
                guard z.isFinite else { continue }

                let normalizedX = Float(gu) / widthDenominator
                guard handRegion.contains(CGPoint(x: CGFloat(normalizedX), y: CGFloat(normalizedY))) else { continue }

                depthSum[idx] += z
                sampleCounts[idx] += 1

                if let colorPlane {
                    // normalizedY is bottom-up (Vision convention); color
                    // buffer rows are top-down, so flip back for the lookup.
                    let cx = min(colorPlane.width - 1, max(0, Int(normalizedX * Float(colorPlane.width))))
                    let cy = min(colorPlane.height - 1, max(0, Int((Float(1) - normalizedY) * Float(colorPlane.height))))
                    let rowPtr = colorPlane.base.advanced(by: cy * colorPlane.bytesPerRow).assumingMemoryBound(to: UInt8.self)
                    let pixelOffset = cx * 4 // BGRA
                    let b = Float(rowPtr[pixelOffset]) / 255
                    let g = Float(rowPtr[pixelOffset + 1]) / 255
                    let r = Float(rowPtr[pixelOffset + 2]) / 255
                    colorSum[idx] += SIMD3<Float>(r, g, b)
                }
            }
        }

        latestIntrinsics = intrinsics
        framesAccumulated += 1
    }

    /// A live, per-cell "how much of this region has been captured so far"
    /// snapshot, meant to be sampled on a throttle during scanning (same
    /// idea/cadence as the live point-cloud overlay) and painted on screen
    /// as a yellow -> white progress wash over the hand.
    ///
    /// Coverage is deliberately *relative*, not measured against a fixed
    /// target sample count: it's each cell's sample count divided by the
    /// best-covered cell seen so far. A hard-coded target (e.g. "12 frames")
    /// would depend on the sensor's actual frame rate, which varies by
    /// device/lighting, and would either finish too early (still-yellow
    /// regions get called "done") or never finish (an unreachable target).
    /// Normalizing against the running max means the whole hand still
    /// trends toward white together as long as it stays in frame and
    /// unoccluded — exactly the "fills in as you hold still" feel wanted —
    /// while a region that entered frame late or was briefly occluded
    /// correctly reads as less-covered relative to the rest.
    func coverageSnapshot() -> CoverageOverlaySnapshot? {
        guard gridWidth > 0, gridHeight > 0 else { return nil }
        let maxCount = sampleCounts.max() ?? 0
        guard maxCount > 0 else { return nil }

        var coverage = [Float](repeating: -1, count: sampleCounts.count)
        for i in sampleCounts.indices where sampleCounts[i] > 0 {
            coverage[i] = Float(sampleCounts[i]) / Float(maxCount)
        }
        return CoverageOverlaySnapshot(coverage: coverage, gridWidth: gridWidth, gridHeight: gridHeight)
    }

    /// The result of a finished capture: the segmented point cloud (for
    /// export / the review-scene point path) plus the raw averaged depth
    /// grid (for `FrontSurfaceMesher`, which needs grid adjacency, not just
    /// a flat point list).
    struct Result {
        var frame: PointCloudFrame
        var depthGrid: [Float]
        /// Averaged per-cell RGB (0...1), parallel to `depthGrid`, or `nil`
        /// if no color buffer was ever available to sample from. Masked
        /// down to the segmented surface the same way `depthGrid` is.
        var colorGrid: [SIMD3<Float>]?
        var gridWidth: Int
        var gridHeight: Int
        var strideVal: Int
        var intrinsics: matrix_float3x3
    }

    /// Finishes the capture: averages every grid cell seen in at least half
    /// the accumulated frames (so one dropped/occluded frame doesn't poke a
    /// hole in the surface), segments out the nearest continuous surface —
    /// the hand/foot, not the background behind it — and unprojects it.
    func finish() -> Result? {
        guard let intrinsics = latestIntrinsics, framesAccumulated > 0, gridWidth > 0 else { return nil }

        let minSamples = max(1, framesAccumulated / 2)
        var averaged = [Float](repeating: .nan, count: depthSum.count)
        let haveColor = !colorSum.isEmpty
        var averagedColor: [SIMD3<Float>]? = haveColor ? [SIMD3<Float>](repeating: .zero, count: colorSum.count) : nil
        for i in depthSum.indices where sampleCounts[i] >= Int32(minSamples) {
            averaged[i] = depthSum[i] / Float(sampleCounts[i])
            if haveColor {
                averagedColor![i] = colorSum[i] / Float(sampleCounts[i])
            }
        }

        let segmented = PointCloudUnprojector.segmentAndUnproject(depthGrid: averaged,
                                                                    gridWidth: gridWidth,
                                                                    gridHeight: gridHeight,
                                                                    strideVal: strideVal,
                                                                    intrinsics: intrinsics)

        // Mask the returned grid down to the segmented surface too, so the
        // mesher builds triangles only over the same region (the subject),
        // not any background that happened to share its depth window.
        var maskedGrid = averaged
        if let keepSet = segmented.keepSet {
            for i in maskedGrid.indices where !keepSet.contains(i) {
                maskedGrid[i] = .nan
            }
            if haveColor {
                for i in averagedColor!.indices where !keepSet.contains(i) {
                    averagedColor![i] = .zero
                }
            }
        }

        return Result(frame: segmented.frame,
                      depthGrid: maskedGrid,
                      colorGrid: averagedColor,
                      gridWidth: gridWidth,
                      gridHeight: gridHeight,
                      strideVal: strideVal,
                      intrinsics: intrinsics)
    }
}

/// A live, per-cell capture-progress snapshot (see
/// `FrontSurfaceCapture.coverageSnapshot()`), meant to be painted as a
/// yellow -> white wash over the hand while scanning is in progress.
///
/// `coverage[i]` is `-1` for a cell that's never had a valid, in-hand-region
/// depth sample (draw nothing there), and in `0...1` — this cell's sample
/// count relative to the best-covered cell so far — everywhere else.
struct CoverageOverlaySnapshot {
    var coverage: [Float]
    var gridWidth: Int
    var gridHeight: Int
}

/// Self-contained ICP (Iterative Closest Point) aligner, used by
/// `PointCloudAccumulator` below for a walk-around, multi-angle scan that
/// stitches frames from a *moving* camera into one merged cloud. This is no
/// longer the default capture flow (see `FrontSurfaceCapture` above, which
/// `FootScanViewModel` uses for the fast single-viewpoint capture) — it's
/// kept here in case a "full 360° scan" mode is wanted later, since building
/// a closed model from every side genuinely does need something like this.
///
/// Since the front TrueDepth camera has no accompanying world-tracking pose
/// (ARWorldTrackingConfiguration only runs on the rear camera), this
/// estimates the rigid transform between consecutive scan frames directly
/// from their geometry.
///
/// This uses **point-to-plane** correspondences (minimizing distance along the
/// target surface's normal) rather than point-to-point (minimizing raw
/// Euclidean distance, à la Horn's method). On curved, largely-featureless
/// organic surfaces like a foot or hand, the true corresponding point rarely
/// sits at the nearest-neighbor's exact position — it sits somewhere along
/// that neighbor's local tangent plane. Point-to-point fights that mismatch
/// every iteration; point-to-plane models it directly, which is why it
/// converges more reliably (fewer iterations, less chance of stalling on a
/// rotation-dominated misalignment) on this kind of subject.
enum ICPAligner {

    /// Aligns `source` onto `target`, returning the transform that maps source -> target
    /// and the transformed source points.
    static func align(source: [SIMD3<Float>],
                       target: [SIMD3<Float>],
                       maxIterations: Int = 20,
                       convergenceThreshold: Float = 1e-6,
                       maxCorrespondenceDistance: Float = 0.009,
                       normalEstimationRadius: Float = 0.005,
                       maxAlignmentPoints: Int = 2500) -> (transform: simd_float4x4, aligned: [SIMD3<Float>]) {

        guard !source.isEmpty, !target.isEmpty else {
            return (matrix_identity_float4x4, source)
        }

        // ICP's per-iteration cost scales directly with how many points it's
        // solving against. A raw TrueDepth frame at close range can carry
        // tens of thousands of points, and running a full nearest-neighbor
        // search + point-to-plane solve against all of them for up to
        // `maxIterations` iterations is exactly what was stalling scans out
        // after the very first frame: each subsequent addFrame() call could
        // take far longer than the accumulator actor's callers were prepared
        // to wait, so nothing after frame 1 ever visibly finished. Solving
        // against a bounded, uniformly-subsampled working set instead keeps
        // the cost of this function roughly constant regardless of capture
        // density; the resulting rigid transform is a single global
        // rotation+translation, so it applies equally well to the full,
        // un-subsampled `source` once it's found.
        let sourceSample = Self.subsample(source, maxCount: maxAlignmentPoints)
        let targetSample = Self.subsample(target, maxCount: maxAlignmentPoints)

        // Point-to-plane needs a surface normal at each target correspondence.
        // Sign doesn't matter here (the residual is squared before summing),
        // so no global normal-orientation pass is needed — just a per-point
        // local tangent-plane estimate.
        let targetNormals = NormalEstimator.estimateNormals(for: targetSample, searchRadius: normalEstimationRadius)

        let targetGrid = SpatialHashGrid(points: targetSample, normals: targetNormals, cellSize: max(normalEstimationRadius, 0.005))
        var current = sourceSample
        var totalTransform = matrix_identity_float4x4
        var previousError: Float = .greatestFiniteMagnitude
        // Correspondences farther apart than this are almost certainly not the
        // same physical point (e.g. an edge of the foot matching noise, or a
        // point with no true match yet because the clouds haven't converged).
        // Without rejecting these, a handful of bad matches can drag the whole
        // rigid-transform solve off course — a classic cause of scans that
        // warp/smear more with every additional frame.
        var distanceGate = maxCorrespondenceDistance

        for _ in 0..<maxIterations {
            // 1. Find nearest-neighbor correspondences (+ their target normal),
            //    rejecting outliers by raw distance same as before.
            var correspondencesSource: [SIMD3<Float>] = []
            var correspondencesTarget: [SIMD3<Float>] = []
            var correspondencesNormal: [SIMD3<Float>] = []
            correspondencesSource.reserveCapacity(current.count)
            correspondencesTarget.reserveCapacity(current.count)
            correspondencesNormal.reserveCapacity(current.count)

            var sumSquaredPlaneDistance: Float = 0
            for p in current {
                guard let match = targetGrid.nearest(to: p) else { continue }
                let d = simd_distance(p, match.point)
                guard d <= distanceGate else { continue }
                correspondencesSource.append(p)
                correspondencesTarget.append(match.point)
                correspondencesNormal.append(match.normal)
                // The quantity point-to-plane actually minimizes: signed
                // distance from p to the target's local tangent plane.
                let planeDistance = simd_dot(match.normal, p - match.point)
                sumSquaredPlaneDistance += planeDistance * planeDistance
            }

            // If almost nothing passed the gate (e.g. a poor initial alignment
            // on the first iteration), relax it rather than solving from a
            // tiny, potentially biased subset of points.
            if correspondencesSource.count < current.count / 10 {
                distanceGate *= 2
                continue
            }

            guard !correspondencesSource.isEmpty else { break }
            let meanError = sumSquaredPlaneDistance / Float(correspondencesSource.count)
            // Tighten the gate as alignment improves so later iterations refine
            // using only genuinely close matches (a simple stand-in for the
            // annealing schedule used in trimmed-ICP variants).
            distanceGate = max(maxCorrespondenceDistance, sqrt(meanError) * 3)

            // 2. Solve for the optimal incremental rigid transform via
            //    linearized point-to-plane least squares.
            guard let stepTransform = PointToPlaneSolver.solve(sourcePoints: correspondencesSource,
                                                                 targetPoints: correspondencesTarget,
                                                                 targetNormals: correspondencesNormal) else {
                // Degenerate system (e.g. all normals nearly parallel) — bail
                // out with whatever alignment we've accumulated so far rather
                // than applying a garbage transform.
                break
            }

            // 3. Apply and accumulate.
            current = current.map { simd_make_float3(stepTransform * SIMD4<Float>($0, 1)) }
            totalTransform = stepTransform * totalTransform

            if abs(previousError - meanError) < convergenceThreshold {
                break
            }
            previousError = meanError
        }

        // Apply the final accumulated transform to the FULL source cloud —
        // everything above only ever touched the bounded sample.
        let alignedFull = source.map { simd_make_float3(totalTransform * SIMD4<Float>($0, 1)) }
        return (totalTransform, alignedFull)
    }

    /// Uniform stride-based subsampling down to at most `maxCount` points.
    /// Deliberately simple (no randomness, no spatial weighting) — for
    /// bounding ICP's cost, an even spread across the array is enough;
    /// it doesn't need to be a statistically unbiased sample.
    private static func subsample(_ points: [SIMD3<Float>], maxCount: Int) -> [SIMD3<Float>] {
        guard points.count > maxCount, maxCount > 0 else { return points }

        var result: [SIMD3<Float>] = []
        result.reserveCapacity(maxCount)
        let step = Double(points.count) / Double(maxCount)
        var accumulator: Double = 0
        var i = 0
        while i < points.count && result.count < maxCount {
            result.append(points[i])
            accumulator += step
            i = Int(accumulator)
        }
        return result
    }
}

/// Solves one linearized point-to-plane ICP step: the incremental rigid
/// transform (rotation + translation) that best satisfies
/// `n_i · (R·p_i + t - q_i) ≈ 0` for every correspondence `(p_i, q_i, n_i)`.
///
/// Standard small-angle linearization: writing the rotation as
/// `R ≈ I + [ω]×` for a rotation vector ω, the per-correspondence residual
/// `n·(p + ω×p + t - q)` is linear in the 6 unknowns `(ω, t)`, so the whole
/// batch reduces to one 6x6 normal-equations solve — no SVD/quaternion step
/// needed, unlike Horn's method.
enum PointToPlaneSolver {

    static func solve(sourcePoints: [SIMD3<Float>],
                       targetPoints: [SIMD3<Float>],
                       targetNormals: [SIMD3<Float>]) -> simd_float4x4? {

        var ATA = [[Float]](repeating: [Float](repeating: 0, count: 6), count: 6)
        var ATb = [Float](repeating: 0, count: 6)

        for i in sourcePoints.indices {
            let p = sourcePoints[i]
            let q = targetPoints[i]
            let n = targetNormals[i]

            // Jacobian row of the residual w.r.t. (ω, t):
            // d/dω [n·(ω×p)] = p×n   (scalar triple product identity)
            // d/dt [n·t]     = n
            let crossTerm = simd_cross(p, n)
            let j: [Float] = [crossTerm.x, crossTerm.y, crossTerm.z, n.x, n.y, n.z]
            let residualConstant = simd_dot(n, p - q)

            for row in 0..<6 {
                for col in row..<6 {
                    ATA[row][col] += j[row] * j[col]
                }
                ATb[row] += -j[row] * residualConstant
            }
        }
        // Mirror the symmetric upper triangle into the lower triangle.
        for row in 0..<6 {
            for col in 0..<row {
                ATA[row][col] = ATA[col][row]
            }
        }
        // Tiny regularization so a degenerate/near-planar correspondence set
        // (too few points, or normals all nearly parallel — e.g. a flat patch
        // with no rotational constraint about that axis) can't produce a
        // singular system.
        for i in 0..<6 { ATA[i][i] += 1e-8 }

        guard let x = LinearSolver6x6.solve(ATA, ATb) else { return nil }

        let omega = SIMD3<Float>(x[0], x[1], x[2])
        let translation = SIMD3<Float>(x[3], x[4], x[5])

        var transform = Self.rodrigues(omega)
        transform.columns.3 = SIMD4<Float>(translation, 1)
        return transform
    }

    /// Exponential map from a rotation vector (axis * angle) to a rotation
    /// matrix via Rodrigues' formula. This is exact for any angle, not just
    /// the first-order `I + [ω]×` approximation the linearization assumed —
    /// using the real exponential map here keeps early iterations (where the
    /// solved ω isn't necessarily tiny) from drifting off a proper rotation.
    private static func rodrigues(_ omega: SIMD3<Float>) -> simd_float4x4 {
        let theta = simd_length(omega)
        guard theta > 1e-8 else { return matrix_identity_float4x4 }

        let axis = omega / theta
        let K = simd_float3x3(rows: [
            SIMD3<Float>(0, -axis.z, axis.y),
            SIMD3<Float>(axis.z, 0, -axis.x),
            SIMD3<Float>(-axis.y, axis.x, 0)
        ])
        let R3 = matrix_identity_float3x3 + sin(theta) * K + (1 - cos(theta)) * (K * K)

        return simd_float4x4(
            SIMD4<Float>(R3.columns.0, 0),
            SIMD4<Float>(R3.columns.1, 0),
            SIMD4<Float>(R3.columns.2, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }
}

/// Solves a dense 6x6 linear system `Ax = b` via Gaussian elimination with
/// partial pivoting. Small and fixed-size enough that a hand-rolled solve is
/// simpler than pulling in Accelerate/LAPACK for this one step.
enum LinearSolver6x6 {

    static func solve(_ matrixA: [[Float]], _ vectorB: [Float]) -> [Float]? {
        let n = 6
        var a = matrixA
        var b = vectorB

        for col in 0..<n {
            var pivotRow = col
            var pivotValue = abs(a[col][col])
            for row in (col + 1)..<n where abs(a[row][col]) > pivotValue {
                pivotValue = abs(a[row][col])
                pivotRow = row
            }
            guard pivotValue > 1e-9 else { return nil } // singular / degenerate system

            if pivotRow != col {
                a.swapAt(col, pivotRow)
                b.swapAt(col, pivotRow)
            }

            let pivot = a[col][col]
            for row in (col + 1)..<n {
                let factor = a[row][col] / pivot
                guard factor != 0 else { continue }
                for k in col..<n {
                    a[row][k] -= factor * a[col][k]
                }
                b[row] -= factor * b[col]
            }
        }

        var x = [Float](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n {
                sum -= a[row][k] * x[k]
            }
            x[row] = sum / a[row][row]
        }
        return x
    }
}

/// Estimates a per-point surface normal from the local neighborhood via
/// plane-fitting (PCA): the normal is the eigenvector of the local
/// covariance matrix with the *smallest* eigenvalue (the direction the
/// neighborhood varies least along, i.e. "out of the surface").
///
/// Implemented with the same dependency-free power-iteration approach used
/// elsewhere in this file, using the standard trick of shifting the matrix
/// (`trace·I - C`) so power iteration — which finds the *largest*-eigenvalue
/// eigenvector — converges to what is actually the smallest eigenvector of
/// the original covariance.
enum NormalEstimator {

    static func estimateNormals(for points: [SIMD3<Float>], searchRadius: Float, minNeighbors: Int = 6) -> [SIMD3<Float>] {
        guard !points.isEmpty else { return [] }

        let grid = RadiusNeighborGrid(points: points, cellSize: searchRadius)
        var normals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 1, 0), count: points.count)

        for i in points.indices {
            let neighbors = grid.neighbors(of: points[i], radius: searchRadius)
            guard neighbors.count >= minNeighbors else { continue }
            normals[i] = planeNormal(of: neighbors)
        }
        return normals
    }

    private static func planeNormal(of neighbors: [SIMD3<Float>]) -> SIMD3<Float> {
        let n = Float(neighbors.count)
        let centroid = neighbors.reduce(SIMD3<Float>.zero, +) / n

        var cxx: Float = 0, cxy: Float = 0, cxz: Float = 0
        var cyy: Float = 0, cyz: Float = 0, czz: Float = 0
        for p in neighbors {
            let d = p - centroid
            cxx += d.x * d.x; cxy += d.x * d.y; cxz += d.x * d.z
            cyy += d.y * d.y; cyz += d.y * d.z
            czz += d.z * d.z
        }

        let covariance = simd_float3x3(rows: [
            SIMD3<Float>(cxx, cxy, cxz),
            SIMD3<Float>(cxy, cyy, cyz),
            SIMD3<Float>(cxz, cyz, czz)
        ])
        let trace = cxx + cyy + czz
        let shifted = trace * matrix_identity_float3x3 - covariance

        var v = SIMD3<Float>(0.4, 0.5, 0.7) // arbitrary non-axis-aligned start
        for _ in 0..<30 {
            let next = shifted * v
            let len = simd_length(next)
            guard len > 1e-10 else { break }
            v = next / len
        }
        return v
    }
}

/// Uniform-grid spatial hash supporting radius-neighborhood queries, used
/// only for local normal estimation (as opposed to `SpatialHashGrid`'s
/// single-nearest-neighbor queries used for ICP correspondences).
final class RadiusNeighborGrid {
    private let cellSize: Float
    private var buckets: [Int64: [SIMD3<Float>]] = [:]

    init(points: [SIMD3<Float>], cellSize: Float) {
        self.cellSize = cellSize
        for p in points {
            buckets[Self.key(for: p, cellSize: cellSize), default: []].append(p)
        }
    }

    func neighbors(of point: SIMD3<Float>, radius: Float) -> [SIMD3<Float>] {
        let cx = Int32((point.x / cellSize).rounded(.down))
        let cy = Int32((point.y / cellSize).rounded(.down))
        let cz = Int32((point.z / cellSize).rounded(.down))
        let radiusSquared = radius * radius

        var result: [SIMD3<Float>] = []
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    let key = Self.key(cx: cx + Int32(dx), cy: cy + Int32(dy), cz: cz + Int32(dz))
                    guard let bucket = buckets[key] else { continue }
                    for candidate in bucket where simd_distance_squared(point, candidate) <= radiusSquared {
                        result.append(candidate)
                    }
                }
            }
        }
        return result
    }

    private static func key(for point: SIMD3<Float>, cellSize: Float) -> Int64 {
        let cx = Int32((point.x / cellSize).rounded(.down))
        let cy = Int32((point.y / cellSize).rounded(.down))
        let cz = Int32((point.z / cellSize).rounded(.down))
        return key(cx: cx, cy: cy, cz: cz)
    }

    private static func key(cx: Int32, cy: Int32, cz: Int32) -> Int64 {
        let ux = Int64(bitPattern: UInt64(UInt32(bitPattern: cx)))
        let uy = Int64(bitPattern: UInt64(UInt32(bitPattern: cy)))
        let uz = Int64(bitPattern: UInt64(UInt32(bitPattern: cz)))
        return (ux << 42) ^ (uy << 21) ^ uz
    }
}

/// Simple uniform-grid spatial hash for approximate nearest-neighbor queries.
/// Adequate for foot-scale point clouds (tens of thousands of points);
/// swap for a k-d tree if you need to scale up significantly.
///
/// Each stored point now carries its estimated surface normal alongside it,
/// so an ICP nearest-neighbor lookup returns everything point-to-plane needs
/// for that correspondence in one query.
final class SpatialHashGrid {
    private let cellSize: Float
    private var buckets: [Int64: [(point: SIMD3<Float>, normal: SIMD3<Float>)]] = [:]

    init(points: [SIMD3<Float>], normals: [SIMD3<Float>], cellSize: Float) {
        self.cellSize = cellSize
        for i in points.indices {
            let key = Self.key(for: points[i], cellSize: cellSize)
            buckets[key, default: []].append((points[i], normals[i]))
        }
    }

    func nearest(to point: SIMD3<Float>) -> (point: SIMD3<Float>, normal: SIMD3<Float>)? {
        let cx = Int32((point.x / cellSize).rounded(.down))
        let cy = Int32((point.y / cellSize).rounded(.down))
        let cz = Int32((point.z / cellSize).rounded(.down))

        var best: (point: SIMD3<Float>, normal: SIMD3<Float>)?
        var bestDistSq = Float.greatestFiniteMagnitude

        // Search the 3x3x3 neighborhood of cells around the query point.
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    let key = Self.key(cx: cx + Int32(dx), cy: cy + Int32(dy), cz: cz + Int32(dz))
                    guard let bucket = buckets[key] else { continue }
                    for candidate in bucket {
                        let d = simd_distance_squared(point, candidate.point)
                        if d < bestDistSq {
                            bestDistSq = d
                            best = candidate
                        }
                    }
                }
            }
        }
        return best
    }

    private static func key(for point: SIMD3<Float>, cellSize: Float) -> Int64 {
        let cx = Int32((point.x / cellSize).rounded(.down))
        let cy = Int32((point.y / cellSize).rounded(.down))
        let cz = Int32((point.z / cellSize).rounded(.down))
        return key(cx: cx, cy: cy, cz: cz)
    }

    private static func key(cx: Int32, cy: Int32, cz: Int32) -> Int64 {
        let ux = Int64(bitPattern: UInt64(UInt32(bitPattern: cx)))
        let uy = Int64(bitPattern: UInt64(UInt32(bitPattern: cy)))
        let uz = Int64(bitPattern: UInt64(UInt32(bitPattern: cz)))
        return (ux << 42) ^ (uy << 21) ^ uz
    }
}

/// Accumulates aligned point cloud frames into a single merged scan,
/// with voxel-grid downsampling to keep point count under control.
actor PointCloudAccumulator {
    private(set) var mergedPoints: [SIMD3<Float>] = []
    private let downsampleVoxelSize: Float

    /// Rough scan-coverage estimate in 0...1, derived from how much cumulative
    /// rotation ICP has resolved between frames. This is a heuristic (it
    /// assumes you're orbiting the phone around a mostly-static foot) — good
    /// enough to give the user a "keep going" / "looks complete" signal, not
    /// a precise surface-coverage measurement.
    private(set) var estimatedCoverage: Float = 0
    private var cumulativeRotationDegrees: Float = 0

    /// Running "this frame's raw camera space -> reference frame" estimate,
    /// carried forward from the most recently integrated frame.
    ///
    /// This is what was actually producing the blob: consecutive integrated
    /// frames are close in time (a slow rotation, ~0.4s apart), so the
    /// previous frame's resolved pose is a genuinely good initial guess for
    /// the next one — but the old code had no such guess at all. It compared
    /// the brand-new frame's *raw, unaligned* camera-space points directly
    /// against `mergedPoints` (which live in the accumulated reference
    /// frame) — coordinate systems that only coincidentally line up right
    /// after the first frame, before much rotation has happened. As the scan
    /// progresses and the camera really has moved, that comparison stops
    /// meaning anything: the "local region" search returns an unrelated
    /// subset of the cloud (or silently falls back to the whole thing), ICP
    /// gets no usable starting point for what can be a large rotation, and
    /// it converges to whatever nearby local minimum it can find — which for
    /// smooth, self-similar geometry like fingers is very often the *wrong*
    /// one. Every frame integrated that way fuses more mismatched geometry
    /// into the cloud, which is exactly what "worked fine early, turned into
    /// a blob as it went on" looks like.
    private var lastAlignmentTransform: simd_float4x4 = matrix_identity_float4x4

    init(downsampleVoxelSize: Float = 0.0015) {
        self.downsampleVoxelSize = downsampleVoxelSize
    }

    /// Adds a new frame, aligning it to the current merged cloud via ICP
    /// (skips alignment for the very first frame, which seeds the model).
    ///
    /// ICP only needs to match against the *local* surface a new frame
    /// actually overlaps with, not the entire scan-so-far — matching against
    /// everything makes every frame more expensive than the last as the scan
    /// progresses, which is how a 30-second scan turns into a many-minute
    /// one. We restrict the target set to merged points falling within a
    /// padded bounding box of the new frame, which is both cheaper and a
    /// better ICP target than the whole cloud (points far outside the new
    /// frame's region can't be genuine correspondences anyway).
    ///
    /// Tightened for hand-scale scanning: fingers are ~1.5-2cm wide with
    /// narrow gaps between them, so a generous neighborhood padding risks
    /// pulling in an *adjacent* finger as a false correspondence and fusing
    /// them together — another concrete way this pipeline could produce a
    /// blob instead of a hand shape, independent of the coordinate-frame bug
    /// above.
    private static let icpNeighborhoodPadding: Float = 0.02 // 2cm

    func addFrame(_ frame: PointCloudFrame) {
        if mergedPoints.isEmpty {
            mergedPoints = frame.points
            lastAlignmentTransform = matrix_identity_float4x4
        } else {
            // Warm-start: bring the new frame into our best current guess of
            // reference-frame coordinates *before* doing the local-region
            // search or handing it to ICP, so both are working with
            // consistent coordinates and a sane initial alignment.
            let warmStarted = frame.points.map { simd_make_float3(lastAlignmentTransform * SIMD4<Float>($0, 1)) }

            let localTarget = Self.localRegion(of: mergedPoints, near: warmStarted, padding: Self.icpNeighborhoodPadding)
            let target = localTarget.isEmpty ? mergedPoints : localTarget
            let (refinementTransform, aligned) = ICPAligner.align(source: warmStarted, target: target)

            mergedPoints.append(contentsOf: aligned)
            // Compose: this frame's full camera-space -> reference-frame
            // transform is the ICP refinement on top of the warm start,
            // and becomes next frame's warm start in turn.
            lastAlignmentTransform = refinementTransform * lastAlignmentTransform
            cumulativeRotationDegrees += Self.rotationAngleDegrees(of: refinementTransform)
            // A full useful scan needs the camera swept around roughly once.
            // This now tracks *genuine incremental* rotation per frame (via
            // the warm-start fix above), where before it was accidentally
            // accumulating something closer to total-rotation-so-far every
            // single frame — so this threshold is intentionally a bit under
            // a full 360° rather than needing an exact full loop, which in
            // practice is rarely achievable at an even sweep speed anyway.
            estimatedCoverage = min(cumulativeRotationDegrees / 260.0, 1.0)
        }
        mergedPoints = Self.voxelDownsample(mergedPoints, voxelSize: downsampleVoxelSize)
    }

    func reset() {
        mergedPoints.removeAll()
        cumulativeRotationDegrees = 0
        estimatedCoverage = 0
        lastAlignmentTransform = matrix_identity_float4x4
    }

    /// A snapshot of what's needed to draw the accumulated model, live,
    /// reprojected into a fresh camera view: a bounded subsample of the
    /// merged cloud so far, plus the pose to view it through.
    struct PoseSnapshot {
        var displayPoints: [SIMD3<Float>]
        var referenceToCamera: simd_float4x4
    }

    /// Refines a fresh camera pose for `framePoints` *without* merging them
    /// into the accumulated cloud or advancing coverage/rotation state.
    ///
    /// This is the piece that makes "the model visibly building on top of
    /// the hand" possible without real ARKit world tracking: it's called far
    /// more often than `addFrame` (a live-feeling overlay refresh, not a
    /// scan-quality merge), and it reuses the hand's own geometry — via the
    /// same ICP correspondence search everything else here uses — as its
    /// anchor, refining the running pose estimate each call rather than
    /// solving from scratch. That's effectively "pick an anchor point in the
    /// view": the anchor is the scanned surface itself, continuously
    /// re-locked-onto, rather than a single fixed point.
    func currentPoseSnapshot(refiningWith framePoints: [SIMD3<Float>]) -> PoseSnapshot? {
        guard !mergedPoints.isEmpty else { return nil }

        let warmStarted = framePoints.map { simd_make_float3(lastAlignmentTransform * SIMD4<Float>($0, 1)) }
        let localTarget = Self.localRegion(of: mergedPoints, near: warmStarted, padding: Self.icpNeighborhoodPadding)
        let target = localTarget.isEmpty ? mergedPoints : localTarget

        // Fewer iterations than the merge path below: this is refining an
        // already-good warm start purely for display, not solving alignment
        // from scratch, so it can afford to be cheaper and run more often.
        let (refinementTransform, _) = ICPAligner.align(source: warmStarted, target: target, maxIterations: 6)
        let cameraFromReference = (refinementTransform * lastAlignmentTransform).inverse

        let displayPoints = Self.subsample(mergedPoints, maxCount: 3000)
        return PoseSnapshot(displayPoints: displayPoints, referenceToCamera: cameraFromReference)
    }

    /// Same uniform stride-based subsampling used to bound ICP's cost in
    /// PointCloudProcessing — reused here to bound how many points get
    /// transformed and handed to the overlay every refresh, regardless of
    /// how large the accumulated cloud has grown.
    private static func subsample(_ points: [SIMD3<Float>], maxCount: Int) -> [SIMD3<Float>] {
        guard points.count > maxCount, maxCount > 0 else { return points }
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(maxCount)
        let step = Double(points.count) / Double(maxCount)
        var accumulator: Double = 0
        var i = 0
        while i < points.count && result.count < maxCount {
            result.append(points[i])
            accumulator += step
            i = Int(accumulator)
        }
        return result
    }

    /// Returns the subset of `points` that fall within `padding` meters of the
    /// axis-aligned bounding box of `framePoints`.
    ///
    /// Callers must pass `framePoints` already warm-started into the same
    /// reference frame `points` lives in — this function has no way to
    /// detect a coordinate-frame mismatch, it'll just silently return a
    /// meaningless (or empty) subset if given mismatched inputs.
    private static func localRegion(of points: [SIMD3<Float>], near framePoints: [SIMD3<Float>], padding: Float) -> [SIMD3<Float>] {
        guard let first = framePoints.first else { return [] }
        var minBound = first
        var maxBound = first
        for p in framePoints {
            minBound = simd_min(minBound, p)
            maxBound = simd_max(maxBound, p)
        }
        let pad = SIMD3<Float>(repeating: padding)
        minBound -= pad
        maxBound += pad

        return points.filter { p in
            p.x >= minBound.x && p.x <= maxBound.x &&
            p.y >= minBound.y && p.y <= maxBound.y &&
            p.z >= minBound.z && p.z <= maxBound.z
        }
    }

    private static func rotationAngleDegrees(of transform: simd_float4x4) -> Float {
        let rotation = simd_float3x3(
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
        let trace = rotation.columns.0.x + rotation.columns.1.y + rotation.columns.2.z
        let cosAngle = max(-1.0, min(1.0, (trace - 1) / 2))
        return Float(acos(Double(cosAngle))) * (180.0 / .pi)
    }

    /// Averages points within each voxel cell to control density and reduce noise.
    private static func voxelDownsample(_ points: [SIMD3<Float>], voxelSize: Float) -> [SIMD3<Float>] {
        var accumulation: [Int64: (sum: SIMD3<Float>, count: Int)] = [:]
        for p in points {
            let cx = Int32((p.x / voxelSize).rounded(.down))
            let cy = Int32((p.y / voxelSize).rounded(.down))
            let cz = Int32((p.z / voxelSize).rounded(.down))
            let key = (Int64(cx) << 42) ^ (Int64(cy) << 21) ^ Int64(cz)
            var entry = accumulation[key] ?? (SIMD3<Float>.zero, 0)
            entry.sum += p
            entry.count += 1
            accumulation[key] = entry
        }
        return accumulation.values.map { $0.sum / Float($0.count) }
    }
}

