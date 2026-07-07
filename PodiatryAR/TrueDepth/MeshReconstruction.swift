import simd
import Foundation

struct ScanMesh {
    var vertices: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var triangleIndices: [UInt32]
    /// Per-vertex RGB (0...1) captured from the color camera at the same
    /// location as each vertex's depth sample, or `nil` when no color data
    /// was available (e.g. `MeshReconstructor`'s voxel path, which merges
    /// points from multiple angles and has no single well-defined color per
    /// voxel face). See `ModelExporter.makeSCNGeometry`, which renders this
    /// as vertex color so the reviewed model looks like the actual scanned
    /// skin instead of a uniform material.
    var vertexColors: [SIMD3<Float>]? = nil
}

/// Builds a mesh from a point cloud.
///
/// This uses voxel occupancy + exposed-face extraction rather than full
/// marching-cubes/Poisson reconstruction. It is deliberately simple so it's
/// auditable and dependency-free, and it produces a genuinely watertight
/// mesh — but the surface will look blocky/faceted before smoothing, and it
/// won't match the fidelity of a dedicated reconstruction library. That's
/// inherent to this method, not a bug to chase away with more smoothing —
/// if a scan's *shape* is right (fingers separated, no fused/blob geometry)
/// but the surface looks faceted, that's this mesher behaving as designed.
///
/// Defaults below are sized for hand-scale scanning (fingers ~1.5-2cm wide):
/// a voxel size tuned for a larger foot would blur out finger-width detail.
///
/// For orthotics-grade output, treat this as the on-device preview/interaction
/// path, and additionally export the raw point cloud (see ModelExporter.exportPLY)
/// to run through a proper reconstruction pipeline (e.g. Open3D's Poisson
/// reconstruction, or MeshLab/Netfabb) before sending anything to a printer.
enum MeshReconstructor {

    static func reconstruct(points: [SIMD3<Float>],
                             voxelSize: Float = 0.0018,
                             smoothingIterations: Int = 8) -> ScanMesh {

        guard !points.isEmpty else {
            return ScanMesh(vertices: [], normals: [], triangleIndices: [])
        }

        let occupied = voxelize(points: points, voxelSize: voxelSize)
        var (vertices, indices) = buildSurfaceMesh(occupiedVoxels: occupied, voxelSize: voxelSize)

        if smoothingIterations > 0 {
            vertices = laplacianSmooth(vertices: vertices, indices: indices, iterations: smoothingIterations)
        }

        let normals = computeVertexNormals(vertices: vertices, indices: indices)
        return ScanMesh(vertices: vertices, normals: normals, triangleIndices: indices)
    }

    // MARK: - Voxelization

    private static func voxelize(points: [SIMD3<Float>], voxelSize: Float) -> Set<SIMD3<Int32>> {
        var voxels = Set<SIMD3<Int32>>()
        voxels.reserveCapacity(points.count)
        for p in points {
            let vx = Int32((p.x / voxelSize).rounded())
            let vy = Int32((p.y / voxelSize).rounded())
            let vz = Int32((p.z / voxelSize).rounded())
            voxels.insert(SIMD3<Int32>(vx, vy, vz))
        }
        return voxels
    }

    // MARK: - Surface extraction (cube "boxel" meshing on exposed faces)

    /// The six face directions and the four corner offsets (in voxel-local
    /// unit-cube space) that make up each face's quad.
    private static let faceDirections: [SIMD3<Int32>] = [
        SIMD3( 1,  0,  0), SIMD3(-1,  0,  0),
        SIMD3( 0,  1,  0), SIMD3( 0, -1,  0),
        SIMD3( 0,  0,  1), SIMD3( 0,  0, -1)
    ]

    private static func buildSurfaceMesh(occupiedVoxels: Set<SIMD3<Int32>>, voxelSize: Float) -> ([SIMD3<Float>], [UInt32]) {
        var vertexLookup: [SIMD3<Float>: UInt32] = [:]
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        func vertexIndex(for position: SIMD3<Float>) -> UInt32 {
            if let existing = vertexLookup[position] { return existing }
            let newIndex = UInt32(vertices.count)
            vertices.append(position)
            vertexLookup[position] = newIndex
            return newIndex
        }

        for voxel in occupiedVoxels {
            let center = SIMD3<Float>(voxel) * voxelSize
            let half = voxelSize * 0.5

            for direction in faceDirections {
                let neighbor = voxel &+ direction
                // Only emit a face where the voxel is exposed to empty space.
                guard !occupiedVoxels.contains(neighbor) else { continue }

                let corners = quadCorners(center: center, half: half, direction: direction)
                let i0 = vertexIndex(for: corners.0)
                let i1 = vertexIndex(for: corners.1)
                let i2 = vertexIndex(for: corners.2)
                let i3 = vertexIndex(for: corners.3)

                // Two triangles per quad, wound so the normal faces outward.
                indices.append(contentsOf: [i0, i1, i2, i0, i2, i3])
            }
        }

        return (vertices, indices)
    }

    private static func quadCorners(center: SIMD3<Float>, half: Float, direction: SIMD3<Int32>) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let d = SIMD3<Float>(direction)
        let faceCenter = center + d * half

        // Pick two axes perpendicular to the face normal to build the quad.
        let (u, v): (SIMD3<Float>, SIMD3<Float>)
        if abs(d.x) > 0.5 {
            u = SIMD3(0, half, 0); v = SIMD3(0, 0, half)
        } else if abs(d.y) > 0.5 {
            u = SIMD3(half, 0, 0); v = SIMD3(0, 0, half)
        } else {
            u = SIMD3(half, 0, 0); v = SIMD3(0, half, 0)
        }

        return (faceCenter - u - v, faceCenter + u - v, faceCenter + u + v, faceCenter - u + v)
    }

    // MARK: - Smoothing

    /// Simple uniform Laplacian smoothing: moves each vertex toward the
    /// average of its neighbors. Softens the blocky voxel look.
    fileprivate static func laplacianSmooth(vertices: [SIMD3<Float>], indices: [UInt32], iterations: Int) -> [SIMD3<Float>] {
        var adjacency = [Int: Set<Int>](minimumCapacity: vertices.count)
        var i = 0
        while i < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            adjacency[a, default: []].formUnion([b, c])
            adjacency[b, default: []].formUnion([a, c])
            adjacency[c, default: []].formUnion([a, b])
            i += 3
        }

        var current = vertices
        for _ in 0..<iterations {
            var next = current
            for (index, neighbors) in adjacency where !neighbors.isEmpty {
                let sum = neighbors.reduce(SIMD3<Float>.zero) { $0 + current[$1] }
                let average = sum / Float(neighbors.count)
                // Blend rather than fully replace, to avoid excessive shrinkage.
                next[index] = simd_mix(current[index], average, SIMD3<Float>(repeating: 0.5))
            }
            current = next
        }
        return current
    }

    fileprivate static func computeVertexNormals(vertices: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        var i = 0
        while i < indices.count {
            let ia = Int(indices[i]), ib = Int(indices[i + 1]), ic = Int(indices[i + 2])
            let a = vertices[ia], b = vertices[ib], c = vertices[ic]
            let faceNormal = simd_cross(b - a, c - a)
            normals[ia] += faceNormal
            normals[ib] += faceNormal
            normals[ic] += faceNormal
            i += 3
        }
        for idx in normals.indices {
            let len = simd_length(normals[idx])
            normals[idx] = len > 1e-8 ? normals[idx] / len : SIMD3<Float>(0, 1, 0)
        }
        return normals
    }
}

/// Builds a mesh directly from a single depth grid — the surface facing the
/// camera, at full sensor resolution — rather than voxelizing a merged,
/// multi-angle point cloud into a closed volume the way `MeshReconstructor`
/// does.
///
/// This is what makes a fast, hold-still capture look like "the front of the
/// hand" instead of a solid block: every vertex here is a real, directly
/// unprojected depth sample, and the mesh is deliberately single-sided/open
/// on the back — there is no data from the back of the object, so none is
/// invented. It also skips voxelization and its Set<SIMD3<Int32>>-based face
/// extraction entirely, which is most of why `MeshReconstructor.reconstruct`
/// is too slow to feel instant: this only ever does one adjacency pass over
/// a grid that's already the right shape for triangulation.
enum FrontSurfaceMesher {

    /// - Parameters:
    ///   - depthGrid: Camera-space depth samples, `.nan` where invalid/absent
    ///     (exactly the shape `FrontSurfaceCapture.finish()` returns).
    ///   - maxEdgeLength: Any grid quad whose corners imply a jump larger
    ///     than this (in meters) is skipped rather than triangulated. This
    ///     is what keeps the silhouette of the hand (or gaps between
    ///     fingers) open instead of the classic heightmap-mesh artifact of
    ///     stretching a triangle across a depth discontinuity to "close" it.
    ///     Loosened from an earlier 0.006 default: TrueDepth's structured-
    ///     light noise is largely a fixed per-pixel pattern (the same dot
    ///     lands on the same pixel every frame), so holding still and
    ///     temporally averaging doesn't cancel it out — at full sensor
    ///     resolution that per-pixel noise routinely exceeded a 6mm gate on
    ///     its own, discarding almost every quad and leaving only the few
    ///     lucky strips where noise happened to align. 0.012 keeps real
    ///     silhouette/finger-gap edges open while giving sensor noise room
    ///     not to fragment the surface — the denoise pass below is the
    ///     actual fix, this is just a safety margin on top of it.
    /// - Parameter colorGrid: Averaged per-cell RGB, parallel to `depthGrid`
    ///   (see `FrontSurfaceCapture.Result.colorGrid`). When present, each
    ///   emitted vertex carries the color sampled at its own grid cell, so
    ///   the reconstructed mesh is a genuine textured capture of the hand
    ///   rather than a flat material — pass `nil` to skip this (e.g. no
    ///   color buffer was ever available).
    static func reconstruct(depthGrid: [Float],
                             colorGrid: [SIMD3<Float>]? = nil,
                             gridWidth: Int,
                             gridHeight: Int,
                             strideVal: Int,
                             intrinsics: matrix_float3x3,
                             maxEdgeLength: Float = 0.012,
                             smoothingIterations: Int = 2) -> ScanMesh {

        guard gridWidth > 1, gridHeight > 1 else {
            return ScanMesh(vertices: [], normals: [], triangleIndices: [])
        }

        // Denoise before triangulation: fill single-cell holes (a cell that
        // dropped out of the averaging window but is fully surrounded by
        // valid neighbors) and then median-filter the depth values. This is
        // what actually fixes "a couple of lines instead of a hand" — the
        // continuity gate above was never the real problem, it just made
        // raw per-pixel sensor noise visible as dropped quads.
        //
        // Hole-filling turns some previously-invalid cells valid, so
        // `colorGrid` — whose validity mirrors `depthGrid`'s in
        // `FrontSurfaceCapture` — needs the same cells filled in lockstep,
        // or those newly-triangulated vertices would sample a color that
        // was never actually captured there (zero/black) instead of an
        // averaged neighbor color.
        let (filledDepth, filledColor) = fillSmallHoles(depthGrid: depthGrid, colorGrid: colorGrid, gridWidth: gridWidth, gridHeight: gridHeight)
        let denoisedGrid = medianDenoise(filledDepth, gridWidth: gridWidth, gridHeight: gridHeight)
        let colorGrid = filledColor

        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y

        var vertexIndexForCell = [Int](repeating: -1, count: denoisedGrid.count)
        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(denoisedGrid.count)
        let wantsColor = colorGrid != nil
        var vertexColors: [SIMD3<Float>] = []
        if wantsColor { vertexColors.reserveCapacity(denoisedGrid.count) }

        for gv in 0..<gridHeight {
            for gu in 0..<gridWidth {
                let idx = gv * gridWidth + gu
                let z = denoisedGrid[idx]
                guard z.isFinite else { continue }

                let u = Float(gu * strideVal)
                let v = Float(gv * strideVal)
                let x = (u - cx) * z / fx
                let y = (v - cy) * z / fy
                // Same (x, -y, -z) convention PointCloudUnprojector uses.
                vertexIndexForCell[idx] = vertices.count
                vertices.append(SIMD3<Float>(x, -y, -z))
                if wantsColor {
                    vertexColors.append(colorGrid![idx])
                }
            }
        }

        guard !vertices.isEmpty else {
            return ScanMesh(vertices: [], normals: [], triangleIndices: [])
        }

        var indices: [UInt32] = []
        for gv in 0..<(gridHeight - 1) {
            for gu in 0..<(gridWidth - 1) {
                let i00 = vertexIndexForCell[gv * gridWidth + gu]
                let i10 = vertexIndexForCell[gv * gridWidth + gu + 1]
                let i01 = vertexIndexForCell[(gv + 1) * gridWidth + gu]
                let i11 = vertexIndexForCell[(gv + 1) * gridWidth + gu + 1]
                guard i00 >= 0, i10 >= 0, i01 >= 0, i11 >= 0 else { continue }

                let v00 = vertices[i00], v10 = vertices[i10]
                let v01 = vertices[i01], v11 = vertices[i11]
                // Checks all 4 perimeter edges of the quad *and* the b-c
                // diagonal (i10-i01) that both triangles below actually use
                // as a shared edge. Checking only the perimeter let a quad
                // through whenever that diagonal alone crossed a real depth
                // discontinuity (a fingertip edge, a silhouette boundary) —
                // the quad "looked" continuous on all 4 sides while hiding
                // a sliver triangle stretched across the diagonal, which is
                // exactly what showed up as long spikes fringing the mesh.
                guard quadIsContinuous(v00, v10, v01, v11, maxEdgeLength: maxEdgeLength) else { continue }

                // Two triangles per quad, wound CCW as seen from +Z so the
                // face normal (cross of the first two edges) actually points
                // toward the camera. The previous winding here traced
                // clockwise from +Z, which put every normal on -Z instead —
                // the mesh was geometrically fine but shaded as if inside
                // out, going dark from the front and only showing detail
                // once rotated around to view the (correctly-lit) back.
                indices.append(contentsOf: [
                    UInt32(i00), UInt32(i01), UInt32(i10),
                    UInt32(i10), UInt32(i01), UInt32(i11)
                ])
            }
        }

        var finalVertices = vertices
        if smoothingIterations > 0 {
            // Smoothing only ever moves vertex *positions* (see
            // laplacianSmooth's signature) and never reorders or drops
            // entries, so `vertexColors` — built in the same iteration
            // order above — stays correctly aligned with `finalVertices`
            // index-for-index after this.
            finalVertices = MeshReconstructor.laplacianSmooth(vertices: vertices, indices: indices, iterations: smoothingIterations)
        }
        let normals = MeshReconstructor.computeVertexNormals(vertices: finalVertices, indices: indices)

        return ScanMesh(vertices: finalVertices,
                         normals: normals,
                         triangleIndices: indices,
                         vertexColors: wantsColor ? vertexColors : nil)
    }

    private static func quadIsContinuous(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, maxEdgeLength: Float) -> Bool {
        simd_distance(a, b) <= maxEdgeLength &&
        simd_distance(a, c) <= maxEdgeLength &&
        simd_distance(b, d) <= maxEdgeLength &&
        simd_distance(c, d) <= maxEdgeLength &&
        simd_distance(b, c) <= maxEdgeLength // the i10-i01 diagonal both triangles share
    }

    // MARK: - Depth-grid denoising

    /// Fills a cell that has no depth sample but is almost entirely
    /// surrounded by cells that do, by averaging those valid neighbors —
    /// and fills `colorGrid` at the same cell from the same neighbors in
    /// lockstep, since its validity mirrors `depthGrid`'s coming out of
    /// `FrontSurfaceCapture` and it would otherwise go stale (zero/black)
    /// at exactly the cells this newly makes valid.
    ///
    /// This targets small, single-cell dropouts — a pixel that just missed
    /// `FrontSurfaceCapture`'s minimum-sample-count threshold — not real
    /// gaps like the space between fingers or the silhouette edge, which
    /// have far fewer valid neighbors around them than `minValidNeighbors`
    /// requires and are deliberately left as `.nan` so `maxEdgeLength` still
    /// keeps them open.
    private static func fillSmallHoles(depthGrid: [Float], colorGrid: [SIMD3<Float>]?, gridWidth: Int, gridHeight: Int, minValidNeighbors: Int = 6) -> ([Float], [SIMD3<Float>]?) {
        guard gridWidth > 0, gridHeight > 0 else { return (depthGrid, colorGrid) }
        var result = depthGrid
        var resultColor = colorGrid
        for gv in 0..<gridHeight {
            for gu in 0..<gridWidth {
                let idx = gv * gridWidth + gu
                guard !depthGrid[idx].isFinite else { continue }

                var depthSum: Float = 0
                var colorSum = SIMD3<Float>.zero
                var count = 0
                for dv in -1...1 {
                    let nv = gv + dv
                    guard nv >= 0, nv < gridHeight else { continue }
                    for du in -1...1 {
                        guard !(du == 0 && dv == 0) else { continue }
                        let nu = gu + du
                        guard nu >= 0, nu < gridWidth else { continue }
                        let nIdx = nv * gridWidth + nu
                        let z = depthGrid[nIdx]
                        guard z.isFinite else { continue }
                        depthSum += z
                        if let colorGrid { colorSum += colorGrid[nIdx] }
                        count += 1
                    }
                }
                guard count >= minValidNeighbors else { continue }
                result[idx] = depthSum / Float(count)
                if colorGrid != nil { resultColor![idx] = colorSum / Float(count) }
            }
        }
        return (result, resultColor)
    }

    /// 3x3 median filter over valid (non-`.nan`) cells only, leaving invalid
    /// cells invalid.
    ///
    /// TrueDepth's structured-light depth carries a largely fixed per-pixel
    /// noise pattern (the same projected dot lands on the same sensor pixel
    /// every frame), so holding still and averaging frames in
    /// `FrontSurfaceCapture` reduces *temporal* noise but leaves that
    /// *spatial* pattern intact — neighboring pixels can still legitimately
    /// differ by several millimeters even on a physically flat patch of
    /// skin. A median (rather than mean) filter was chosen specifically
    /// because it knocks down that kind of per-pixel spike without also
    /// blurring across genuine depth edges (finger silhouettes, the gap
    /// between fingers) the way an averaging blur would.
    private static func medianDenoise(_ depthGrid: [Float], gridWidth: Int, gridHeight: Int, radius: Int = 1) -> [Float] {
        guard gridWidth > 0, gridHeight > 0 else { return depthGrid }
        var result = depthGrid
        var neighborhood: [Float] = []
        neighborhood.reserveCapacity((2 * radius + 1) * (2 * radius + 1))

        for gv in 0..<gridHeight {
            for gu in 0..<gridWidth {
                let idx = gv * gridWidth + gu
                guard depthGrid[idx].isFinite else { continue }

                neighborhood.removeAll(keepingCapacity: true)
                for dv in -radius...radius {
                    let nv = gv + dv
                    guard nv >= 0, nv < gridHeight else { continue }
                    for du in -radius...radius {
                        let nu = gu + du
                        guard nu >= 0, nu < gridWidth else { continue }
                        let z = depthGrid[nv * gridWidth + nu]
                        guard z.isFinite else { continue }
                        neighborhood.append(z)
                    }
                }
                guard !neighborhood.isEmpty else { continue }
                neighborhood.sort()
                result[idx] = neighborhood[neighborhood.count / 2]
            }
        }
        return result
    }
}
