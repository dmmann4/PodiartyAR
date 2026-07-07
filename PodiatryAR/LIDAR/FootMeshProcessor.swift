import ARKit
import ModelIO
import simd

struct FootMeasurements {
    let lengthMM: Float
    let widthMM: Float
    let archHeightMM: Float
}

/// A plain triangle mesh in world space — the common currency between capture,
/// ML, the viewer, and export.
struct FootMesh {
    var vertices: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var triangleIndices: [UInt32]
}

/// ARGeometrySource and ARGeometryElement are thin wrappers around a raw MTLBuffer —
/// there's no array subscript on them. These helpers do the pointer arithmetic ARKit
/// expects you to do yourself (this is the same pattern Apple's own mesh-visualization
/// sample code uses).
extension ARMeshGeometry {
    func vertex(at index: UInt32) -> SIMD3<Float> {
        precondition(vertices.format == .float3, "Expected three floats per vertex.")
        let pointer = vertices.buffer.contents()
            .advanced(by: vertices.offset + vertices.stride * Int(index))
        return pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
    }

    func normalValue(at index: UInt32) -> SIMD3<Float> {
        precondition(normals.format == .float3, "Expected three floats per normal.")
        let pointer = normals.buffer.contents()
            .advanced(by: normals.offset + normals.stride * Int(index))
        return pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
    }

    /// ARKit mesh faces are always triangles (indexCountPerPrimitive == 3), with
    /// 32-bit indices, but we read both values from the buffer rather than assume
    /// them, since that's what they're there for.
    func vertexIndices(ofFaceAt faceIndex: Int) -> [UInt32] {
        let indicesPerFace = faces.indexCountPerPrimitive
        precondition(faces.bytesPerIndex == MemoryLayout<UInt32>.size, "Expected 32-bit face indices.")
        let facesPointer = faces.buffer.contents()

        var result: [UInt32] = []
        result.reserveCapacity(indicesPerFace)
        for offset in 0..<indicesPerFace {
            let byteOffset = (faceIndex * indicesPerFace + offset) * MemoryLayout<UInt32>.size
            let value = facesPointer.advanced(by: byteOffset)
                .assumingMemoryBound(to: UInt32.self).pointee
            result.append(value)
        }
        return result
    }

    /// Returns ARKit's surface classification for a given face index.
    /// The classification buffer stores one UInt8 per face.
    func classificationOf(faceAt faceIndex: Int) -> ARMeshClassification {
        guard let classificationData = classification else { return .none }
        let classificationPtr = classificationData.buffer.contents()
            .advanced(by: classificationData.offset + faceIndex * classificationData.stride)
        let rawValue = classificationPtr.assumingMemoryBound(to: UInt8.self).pointee
        return ARMeshClassification(rawValue: Int(rawValue)) ?? .none
    }
}

enum FootMeshProcessor {

    // MARK: - Fusion

    /// ARKit mesh classification labels to exclude when fusing anchors. These are
    /// structural environment geometry — never foot. "floor" is kept so
    /// FootMeshProcessor.isolateFoot can use it to estimate the ground plane;
    /// it gets stripped in Stage 1 of that function.
    private static let excludedClassifications: Set<ARMeshClassification> = [
        .wall, .ceiling, .door, .seat, .table, .window
    ]

    /// Combines every ARMeshAnchor into a single world-space mesh, skipping faces
    /// that ARKit has classified as structural environment (walls, ceiling, etc.).
    /// ARMeshAnchors overlap where ARKit re-observed the same surface, so this is a
    /// simple concatenation rather than true mesh stitching — smooth and decimate
    /// later to clean up seams.
    static func fuse(_ anchors: [ARMeshAnchor]) -> FootMesh {
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        for anchor in anchors {
            let geometry = anchor.geometry
            let transform = anchor.transform
            let baseIndex = UInt32(vertices.count)

            // Build a local vertex array for this anchor first (we only emit
            // vertices actually referenced by kept faces, but building the full
            // local array up-front keeps the index arithmetic simple).
            var localVertices: [SIMD3<Float>] = []
            var localNormals:  [SIMD3<Float>] = []
            localVertices.reserveCapacity(geometry.vertices.count)
            localNormals.reserveCapacity(geometry.vertices.count)

            for i in 0..<geometry.vertices.count {
                let local = geometry.vertex(at: UInt32(i))
                let world = transform * SIMD4<Float>(local, 1)
                localVertices.append(SIMD3(world.x, world.y, world.z))

                let n = geometry.normalValue(at: UInt32(i))
                let worldNormal = simd_normalize((transform * SIMD4<Float>(n, 0)).xyz)
                localNormals.append(worldNormal)
            }

            // Emit only faces whose ARKit classification is not excluded.
            for f in 0..<geometry.faces.count {
                let classification = geometry.classificationOf(faceAt: f)
                if excludedClassifications.contains(classification) { continue }

                let faceVertexIndices = geometry.vertexIndices(ofFaceAt: f)
                for vertexIndex in faceVertexIndices {
                    indices.append(baseIndex + vertexIndex)
                }
            }

            vertices.append(contentsOf: localVertices)
            normals.append(contentsOf: localNormals)
        }

        return FootMesh(vertices: vertices, normals: normals, triangleIndices: indices)
    }

    // MARK: - Foot isolation

    /// Maximum physical dimensions we'd ever expect for a human foot (in metres).
    /// Anything larger is almost certainly surrounding environment, not foot geometry.
    private static let maxFootLength: Float = 0.36   // ~US men's size 18
    private static let maxFootWidth:  Float = 0.16
    private static let maxFootHeight: Float = 0.12   // top of ankle

    /// Multi-stage foot isolation:
    ///   1. Strip the floor (and anything below it).
    ///   2. Clamp to a physically plausible foot bounding volume centred on the
    ///      densest cluster of geometry — eliminates walls, furniture, and anything
    ///      more than ~36 cm away from the foot's centre of mass.
    ///   3. Extract the largest connected component — drops isolated noise patches
    ///      (stray geometry, shoe edges) that survive the bounding-box filter.
    static func isolateFoot(_ mesh: FootMesh, floorY: Float, floorMargin: Float = 0.015) -> FootMesh {

        // ── Stage 1: floor removal ────────────────────────────────────────────
        let aboveFloor = filterVertices(mesh) { $0.y > floorY + floorMargin }
        guard !aboveFloor.vertices.isEmpty else { return aboveFloor }

        // ── Stage 2: bounding-volume clamp ───────────────────────────────────
        // Centroid of what's above the floor is a robust proxy for foot centre;
        // anything outside maxFoot* in any axis is environment, not foot.
        let centroid = aboveFloor.vertices.reduce(SIMD3<Float>.zero, +)
            / Float(aboveFloor.vertices.count)

        let halfL = maxFootLength / 2
        let halfW = maxFootWidth  / 2

        let bounded = filterVertices(aboveFloor) { v in
            abs(v.x - centroid.x) < halfW   &&
            abs(v.z - centroid.z) < halfL   &&
            (v.y - floorY)        < maxFootHeight
        }
        guard !bounded.vertices.isEmpty else { return bounded }

        // ── Stage 3: largest connected component ──────────────────────────────
        return largestConnectedComponent(bounded)
    }

    /// Keeps only vertices/triangles matching `predicate`, remapping indices.
    private static func filterVertices(_ mesh: FootMesh,
                                       _ predicate: (SIMD3<Float>) -> Bool) -> FootMesh {
        var keptVertices: [SIMD3<Float>] = []
        var keptNormals:  [SIMD3<Float>] = []
        var remap = [Int: UInt32]()

        for (i, v) in mesh.vertices.enumerated() where predicate(v) {
            remap[i] = UInt32(keptVertices.count)
            keptVertices.append(v)
            keptNormals.append(mesh.normals[i])
        }

        var keptIndices = [UInt32]()
        keptIndices.reserveCapacity(mesh.triangleIndices.count)
        var i = 0
        while i < mesh.triangleIndices.count {
            let a = Int(mesh.triangleIndices[i])
            let b = Int(mesh.triangleIndices[i + 1])
            let c = Int(mesh.triangleIndices[i + 2])
            if let ra = remap[a], let rb = remap[b], let rc = remap[c] {
                keptIndices.append(contentsOf: [ra, rb, rc])
            }
            i += 3
        }
        return FootMesh(vertices: keptVertices, normals: keptNormals, triangleIndices: keptIndices)
    }

    /// Union-Find (path-compressed) connected-component extraction.
    /// Vertices are "connected" when they share a triangle edge.  We keep only
    /// the component with the most vertices — that's almost always the foot.
    private static func largestConnectedComponent(_ mesh: FootMesh) -> FootMesh {
        let n = mesh.vertices.count
        guard n > 0 else { return mesh }

        // Union-Find with path compression + rank
        var parent = Array(0..<n)
        var rank   = [Int](repeating: 0, count: n)

        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            if rank[ra] < rank[rb] { parent[ra] = rb }
            else if rank[ra] > rank[rb] { parent[rb] = ra }
            else { parent[rb] = ra; rank[ra] += 1 }
        }

        // Build adjacency from triangle edges
        var i = 0
        while i < mesh.triangleIndices.count {
            let a = Int(mesh.triangleIndices[i])
            let b = Int(mesh.triangleIndices[i + 1])
            let c = Int(mesh.triangleIndices[i + 2])
            union(a, b); union(b, c); union(a, c)
            i += 3
        }

        // Find component sizes and pick the largest
        var sizes = [Int: Int]()
        for v in 0..<n { sizes[find(v), default: 0] += 1 }
        guard let largestRoot = sizes.max(by: { $0.value < $1.value })?.key else {
            return mesh
        }

        // Filter to the winning component.
        // We can't use a closure here because `find` mutates `parent` (path compression);
        // instead we build the remap table directly with an index loop.
        var remap = [Int: UInt32]()
        var keptVertices = [SIMD3<Float>]()
        var keptNormals  = [SIMD3<Float>]()

        for v in 0..<n where find(v) == largestRoot {
            remap[v] = UInt32(keptVertices.count)
            keptVertices.append(mesh.vertices[v])
            keptNormals.append(mesh.normals[v])
        }

        var keptIndices = [UInt32]()
        var j = 0
        while j < mesh.triangleIndices.count {
            let a = Int(mesh.triangleIndices[j])
            let b = Int(mesh.triangleIndices[j + 1])
            let c = Int(mesh.triangleIndices[j + 2])
            if let ra = remap[a], let rb = remap[b], let rc = remap[c] {
                keptIndices.append(contentsOf: [ra, rb, rc])
            }
            j += 3
        }
        return FootMesh(vertices: keptVertices, normals: keptNormals, triangleIndices: keptIndices)
    }

    // MARK: - Smoothing

    /// One pass of Laplacian smoothing: each vertex moves toward the average position
    /// of its neighbors. Cheap, pure Swift, and removes most LiDAR-induced noise.
    static func smooth(_ mesh: FootMesh, iterations: Int = 2, factor: Float = 0.5) -> FootMesh {
        var adjacency = [[Int]](repeating: [], count: mesh.vertices.count)
        var i = 0
        while i < mesh.triangleIndices.count {
            let a = Int(mesh.triangleIndices[i])
            let b = Int(mesh.triangleIndices[i + 1])
            let c = Int(mesh.triangleIndices[i + 2])
            adjacency[a].append(contentsOf: [b, c])
            adjacency[b].append(contentsOf: [a, c])
            adjacency[c].append(contentsOf: [a, b])
            i += 3
        }

        var vertices = mesh.vertices
        for _ in 0..<iterations {
            var next = vertices
            for (idx, neighbors) in adjacency.enumerated() where !neighbors.isEmpty {
                let sum = neighbors.reduce(SIMD3<Float>.zero) { $0 + vertices[$1] }
                let average = sum / Float(neighbors.count)
                next[idx] = simd_mix(vertices[idx], average, SIMD3(repeating: factor))
            }
            vertices = next
        }

        return FootMesh(vertices: vertices, normals: mesh.normals, triangleIndices: mesh.triangleIndices)
    }

    // MARK: - Decimation

    /// Grid-based vertex clustering: collapses all vertices within each voxel to
    /// their centroid. Simple, pure Swift, and effective for cleaning up the dense,
    /// overlapping geometry produced by fusing many ARMeshAnchors.
    static func decimate(_ mesh: FootMesh, voxelSizeMM: Float = 1.5) -> FootMesh {
        let voxelSize = voxelSizeMM / 1000
        var cells: [SIMD3<Int32>: (sum: SIMD3<Float>, count: Int)] = [:]

        for v in mesh.vertices {
            let cell = SIMD3<Int32>(
                Int32((v.x / voxelSize).rounded(.down)),
                Int32((v.y / voxelSize).rounded(.down)),
                Int32((v.z / voxelSize).rounded(.down))
            )
            var entry = cells[cell] ?? (.zero, 0)
            entry.sum += v
            entry.count += 1
            cells[cell] = entry
        }

        var cellToIndex: [SIMD3<Int32>: UInt32] = [:]
        var newVertices: [SIMD3<Float>] = []
        for (cell, entry) in cells {
            cellToIndex[cell] = UInt32(newVertices.count)
            newVertices.append(entry.sum / Float(entry.count))
        }

        func cellFor(_ v: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(
                Int32((v.x / voxelSize).rounded(.down)),
                Int32((v.y / voxelSize).rounded(.down)),
                Int32((v.z / voxelSize).rounded(.down))
            )
        }

        var newIndices: [UInt32] = []
        var i = 0
        while i < mesh.triangleIndices.count {
            let a = cellToIndex[cellFor(mesh.vertices[Int(mesh.triangleIndices[i])])]!
            let b = cellToIndex[cellFor(mesh.vertices[Int(mesh.triangleIndices[i + 1])])]!
            let c = cellToIndex[cellFor(mesh.vertices[Int(mesh.triangleIndices[i + 2])])]!
            if a != b, b != c, a != c {
                newIndices.append(contentsOf: [a, b, c])
            }
            i += 3
        }

        // Normals are dropped here for simplicity; recompute from face geometry
        // before export if you need shaded rendering.
        let zeroNormals = [SIMD3<Float>](repeating: .zero, count: newVertices.count)
        return FootMesh(vertices: newVertices, normals: zeroNormals, triangleIndices: newIndices)
    }

    // MARK: - Non-ML measurement fallback

    /// PCA-based length/width/height. Useful as a sanity check against the ML
    /// landmark model, or as a fallback before you've trained one.
    static func boundingMeasurements(_ mesh: FootMesh) -> FootMeasurements {
        let n = Float(mesh.vertices.count)
        let centroid = mesh.vertices.reduce(SIMD3<Float>.zero, +) / n

        var covariance = simd_float3x3(0)
        for v in mesh.vertices {
            let d = v - centroid
            covariance.columns.0 += SIMD3(d.x * d.x, d.y * d.x, d.z * d.x)
            covariance.columns.1 += SIMD3(d.x * d.y, d.y * d.y, d.z * d.y)
            covariance.columns.2 += SIMD3(d.x * d.z, d.y * d.z, d.z * d.z)
        }
        covariance = covariance * (1 / n)

        // Power iteration for the principal (longest) axis — adequate for a roughly
        // foot-shaped point cloud; swap for a full eigendecomposition (Accelerate's
        // LAPACK bindings) if you need the full basis.
        var principal = SIMD3<Float>(1, 0, 0)
        for _ in 0..<25 {
            principal = simd_normalize(covariance * principal)
        }

        var minProj: Float = .greatestFiniteMagnitude
        var maxProj: Float = -.greatestFiniteMagnitude
        var minWidth: Float = .greatestFiniteMagnitude
        var maxWidth: Float = -.greatestFiniteMagnitude
        var maxHeight: Float = -.greatestFiniteMagnitude

        let lateral = simd_normalize(simd_cross(principal, SIMD3(0, 1, 0)))

        for v in mesh.vertices {
            let d = v - centroid
            let proj = simd_dot(d, principal)
            let wide = simd_dot(d, lateral)
            minProj = min(minProj, proj); maxProj = max(maxProj, proj)
            minWidth = min(minWidth, wide); maxWidth = max(maxWidth, wide)
            maxHeight = max(maxHeight, v.y)
        }

        let floorY = mesh.vertices.map(\.y).min() ?? 0
        return FootMeasurements(
            lengthMM: (maxProj - minProj) * 1000,
            widthMM: (maxWidth - minWidth) * 1000,
            archHeightMM: (maxHeight - floorY) * 1000
        )
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
