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
}

enum FootMeshProcessor {

    // MARK: - Fusion

    /// Combines every ARMeshAnchor into a single world-space mesh. ARMeshAnchors
    /// overlap where ARKit re-observed the same surface, so this is a simple
    /// concatenation rather than true mesh stitching — FootMeshProcessor.smooth
    /// and a later decimation pass clean up the seams.
    static func fuse(_ anchors: [ARMeshAnchor]) -> FootMesh {
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        for anchor in anchors {
            let geometry = anchor.geometry
            let transform = anchor.transform
            let baseIndex = UInt32(vertices.count)

            for i in 0..<geometry.vertices.count {
                let local = geometry.vertex(at: UInt32(i))
                let world = transform * SIMD4<Float>(local, 1)
                vertices.append(SIMD3(world.x, world.y, world.z))

                let n = geometry.normalValue(at: UInt32(i))
                let worldNormal = simd_normalize((transform * SIMD4<Float>(n, 0)).xyz)
                normals.append(worldNormal)
            }

            for f in 0..<geometry.faces.count {
                let faceVertexIndices = geometry.vertexIndices(ofFaceAt: f)
                for vertexIndex in faceVertexIndices {
                    indices.append(baseIndex + vertexIndex)
                }
            }
        }

        return FootMesh(vertices: vertices, normals: normals, triangleIndices: indices)
    }

    // MARK: - Foot isolation

    /// Removes the floor and anything outside a generous bounding volume around the
    /// densest cluster of geometry (a stand-in for a learned segmenter — see the
    /// README for when to upgrade this to ML).
    static func isolateFoot(_ mesh: FootMesh, floorY: Float, floorMargin: Float = 0.015) -> FootMesh {
        var keptVertices: [SIMD3<Float>] = []
        var keptNormals: [SIMD3<Float>] = []
        var remap: [Int: UInt32] = [:]

        for (i, v) in mesh.vertices.enumerated() {
            if v.y > floorY + floorMargin {
                remap[i] = UInt32(keptVertices.count)
                keptVertices.append(v)
                keptNormals.append(mesh.normals[i])
            }
        }

        var keptIndices: [UInt32] = []
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
