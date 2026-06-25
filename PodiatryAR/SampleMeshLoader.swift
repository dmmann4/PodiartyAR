import ModelIO
import simd

enum SampleMeshLoaderError: Error {
    case noMeshFound
    case missingPositionData
}

/// Lets you exercise FootMeshProcessor / FootLandmarkML / InteractiveFootView /
/// MeshExporter without ARKit, LiDAR, or a physical device at all — useful for
/// testing the back half of the pipeline in the simulator, or on a non-LiDAR phone.
enum SampleMeshLoader {

    /// Loads the first mesh found in any file Model I/O can read (OBJ, USDZ, etc).
    /// Point this at a free foot-last or shoe model you've added to the app bundle
    /// for something closer to a realistic test shape.
    static func loadFootMesh(from url: URL) throws -> FootMesh {
        let asset = MDLAsset(url: url)
        guard let mdlMesh = (asset.childObjects(of: MDLMesh.self) as? [MDLMesh])?.first else {
            throw SampleMeshLoaderError.noMeshFound
        }
        return try convert(mdlMesh)
    }

    /// Procedurally generated foot mesh built by lofting cross-section ellipses
    /// along an anatomical sole curve. Much closer to a real foot shape than a box —
    /// useful for testing landmark placement, arch height measurement, and the viewer
    /// on a non-LiDAR device or simulator, without requiring any bundled asset file.
    ///
    /// Anatomy encoded:
    ///   • Sole curve: slight heel-to-arch rise then toe drop (realistic arch profile)
    ///   • Cross-sections: ellipses that narrow at heel and toes, widen at the ball
    ///   • Dorsum height: lower at heel and toes, peaks over the arch
    ///   • Toe cap: a rounded ellipsoid closing off the front
    ///
    /// Coordinate convention matches ARKit world space as captured by LiDAR:
    ///   +X = lateral (toward little toe), +Y = up, +Z = toward heel
    static func proceduralTestFoot() -> FootMesh {
        var vertices:  [SIMD3<Float>] = []
        var normals:   [SIMD3<Float>] = []
        var indices:   [UInt32]       = []

        // ── Anatomical constants (metres) ──────────────────────────────────────
        let footLength:   Float = 0.260   // heel to longest toe (EU 40 / US men's 7)
        let ballWidth:    Float = 0.092   // widest point at metatarsal heads
        let heelWidth:    Float = 0.058
        let dorsumHeight: Float = 0.068   // max height at arch peak
        let heelHeight:   Float = 0.038   // height at heel cross-section

        // Number of cross-section rings along the Z axis (heel → toe).
        // More rings = smoother arch curve.
        let ringCount    = 28
        let spokeCount   = 20   // vertices around each elliptical ring

        // ── Sole curve & cross-section parameters sampled per ring ─────────────
        // t = 0 at heel, t = 1 at toe tip.
        func soleY(_ t: Float) -> Float {
            // Heel sits at heelHeight/2, rises to arch peak around t=0.38,
            // then drops back down to near-floor at the toe box.
            let arch = sin(t * .pi) * 0.018          // gentle arch rise
            let heelDrop = (1 - t) * (1 - t) * -0.006  // heel slightly lower
            return arch + heelDrop
        }

        func halfWidth(_ t: Float) -> Float {
            // Narrow heel, widest at ball (~t=0.62), tapers to narrow toe.
            let ballT: Float = 0.62
            if t < ballT {
                // Heel to ball: quadratic widen
                let u = t / ballT
                return heelWidth / 2 + (ballWidth / 2 - heelWidth / 2) * u * u
            } else {
                // Ball to toe: linear taper
                let u = (t - ballT) / (1 - ballT)
                return ballWidth / 2 * (1 - u * 0.78)
            }
        }

        func halfHeight(_ t: Float) -> Float {
            // Cross-section height (dorsum): low at heel, peaks over arch, low at toe.
            let base = heelHeight / 2
            let peak = dorsumHeight / 2
            return base + (peak - base) * sin(min(t * 1.6, .pi))
        }

        // Lateral offset: foot is slightly wider on the medial (inner) side.
        func lateralOffset(_ t: Float) -> Float {
            return sin(t * .pi) * 0.006
        }

        // ── Build rings ────────────────────────────────────────────────────────
        // Z goes from footLength (heel) down to 0 (toe tip) so +Z = heel,
        // matching ARKit's captured coordinate system.
        for ring in 0..<ringCount {
            let t     = Float(ring) / Float(ringCount - 1)      // 0 = heel, 1 = toe
            let z     = footLength * (1 - t)                    // world Z
            let y0    = soleY(t)                                 // sole height
            let hw    = halfWidth(t)
            let hh    = halfHeight(t)
            let xOff  = lateralOffset(t)

            for spoke in 0..<spokeCount {
                // Angle around the elliptical cross-section.
                // 0 = lateral (+X), π = medial (−X), bottom half = sole.
                let angle = 2 * Float.pi * Float(spoke) / Float(spokeCount)
                let px = xOff + hw * cos(angle)
                let py = y0   + hh * (sin(angle) * 0.5 + 0.5)  // 0..hh range → floor to dorsum
                vertices.append(SIMD3(px, py, z))
            }
        }

        // ── Toe cap (rounded ellipsoid closing the front) ─────────────────────
        let capRings = 8
        let toeT: Float = 1.0
        let capHW = halfWidth(toeT) * 0.6
        let capHH = halfHeight(toeT) * 0.55
        let capY0 = soleY(toeT)
        let capZ  = Float(0)

        for capRing in 1...capRings {
            let phi = Float.pi * Float(capRing) / Float(capRings * 2)   // 0..π/2
            let ringScale = cos(phi)
            let zOff      = -sin(phi) * capHW * 0.8   // cap extends forward in -Z

            for spoke in 0..<spokeCount {
                let angle = 2 * Float.pi * Float(spoke) / Float(spokeCount)
                let px = capHW * ringScale * cos(angle)
                let py = capY0 + capHH * (ringScale * (sin(angle) * 0.5 + 0.5))
                vertices.append(SIMD3(px, py, capZ + zOff))
            }
        }

        // Tip vertex
        let tipIndex = UInt32(vertices.count)
        vertices.append(SIMD3(0, capY0 + capHH * 0.25, capZ - capHW * 0.8))

        // ── Heel cap ─────────────────────────────────────────────────────────
        let heelCapRings = 6
        let heelT: Float = 0.0
        let heelHW = halfWidth(heelT)
        let heelHH = halfHeight(heelT)
        let heelY0 = soleY(heelT)
        let heelZ  = footLength

        for capRing in 1...heelCapRings {
            let phi = Float.pi * Float(capRing) / Float(heelCapRings * 2)
            let ringScale = cos(phi)
            let zOff = sin(phi) * heelHW * 0.7

            for spoke in 0..<spokeCount {
                let angle = 2 * Float.pi * Float(spoke) / Float(spokeCount)
                let px = heelHW * ringScale * cos(angle)
                let py = heelY0 + heelHH * (ringScale * (sin(angle) * 0.5 + 0.5))
                vertices.append(SIMD3(px, py, heelZ + zOff))
            }
        }

        let heelTipIndex = UInt32(vertices.count)
        vertices.append(SIMD3(0, heelY0 + heelHH * 0.2, heelZ + heelHW * 0.65))

        // ── Stitch rings into triangles ────────────────────────────────────────
        let totalRings = ringCount + capRings + heelCapRings   // for reference

        func ringBase(_ ring: Int) -> UInt32 { UInt32(ring * spokeCount) }

        // Main body rings
        for ring in 0..<(ringCount - 1) {
            let base0 = ringBase(ring)
            let base1 = ringBase(ring + 1)
            for s in 0..<spokeCount {
                let next = (s + 1) % spokeCount
                let a = base0 + UInt32(s);    let b = base0 + UInt32(next)
                let c = base1 + UInt32(s);    let d = base1 + UInt32(next)
                indices.append(contentsOf: [a, b, c,  b, d, c])
            }
        }

        // Toe cap rings — first cap ring connects to last body ring
        let lastBodyRing = ringCount - 1
        for capRing in 0..<capRings {
            let ring0 = lastBodyRing + capRing
            let ring1 = ring0 + 1
            let base0 = ringBase(ring0)
            let base1 = ringBase(ring1)
            for s in 0..<spokeCount {
                let next = (s + 1) % spokeCount
                let a = base0 + UInt32(s);    let b = base0 + UInt32(next)
                let c = base1 + UInt32(s);    let d = base1 + UInt32(next)
                indices.append(contentsOf: [a, b, c,  b, d, c])
            }
        }

        // Fan-stitch the toe tip to the last cap ring
        let lastCapRingBase = ringBase(lastBodyRing + capRings)
        for s in 0..<spokeCount {
            let next = (s + 1) % spokeCount
            indices.append(contentsOf: [
                lastCapRingBase + UInt32(s),
                lastCapRingBase + UInt32(next),
                tipIndex
            ])
        }

        // Heel cap rings — first heel cap ring connects to ring 0 (heel end)
        for capRing in 0..<heelCapRings {
            let ring0 = (capRing == 0) ? 0 : (ringCount + capRings + capRing - 1)
            let ring1 = ringCount + capRings + capRing
            let base0 = ringBase(ring0)
            let base1 = ringBase(ring1)
            for s in 0..<spokeCount {
                let next = (s + 1) % spokeCount
                let a = base0 + UInt32(s);    let b = base0 + UInt32(next)
                let c = base1 + UInt32(s);    let d = base1 + UInt32(next)
                indices.append(contentsOf: [a, c, b,  b, c, d])  // reversed winding for heel
            }
        }

        // Fan-stitch heel tip
        let lastHeelRingBase = ringBase(ringCount + capRings + heelCapRings - 1)
        for s in 0..<spokeCount {
            let next = (s + 1) % spokeCount
            indices.append(contentsOf: [
                lastHeelRingBase + UInt32(next),
                lastHeelRingBase + UInt32(s),
                heelTipIndex
            ])
        }

        // ── Compute smooth vertex normals from face normals ────────────────────
        normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        var i = 0
        while i < indices.count {
            let ia = Int(indices[i]), ib = Int(indices[i+1]), ic = Int(indices[i+2])
            let edge1 = vertices[ib] - vertices[ia]
            let edge2 = vertices[ic] - vertices[ia]
            let faceNormal = simd_cross(edge1, edge2)   // not normalised — area-weighted
            normals[ia] += faceNormal
            normals[ib] += faceNormal
            normals[ic] += faceNormal
            i += 3
        }
        normals = normals.map { n in
            let len = simd_length(n)
            return len > 0 ? n / len : SIMD3(0, 1, 0)
        }

        return FootMesh(vertices: vertices, normals: normals, triangleIndices: indices)
    }

    // MARK: - Shared conversion

    private static func convert(_ mdlMesh: MDLMesh) throws -> FootMesh {
        // Make sure normals exist even if the source file didn't include any.
        mdlMesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)

        guard let positionData = mdlMesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else {
            throw SampleMeshLoaderError.missingPositionData
        }
        let normalData = mdlMesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal, as: .float3)

        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        vertices.reserveCapacity(mdlMesh.vertexCount)
        normals.reserveCapacity(mdlMesh.vertexCount)

        for i in 0..<mdlMesh.vertexCount {
            let vertexPointer = positionData.dataStart.advanced(by: i * positionData.stride)
            vertices.append(vertexPointer.withMemoryRebound(to: Float.self, capacity: 3) { ptr in
                SIMD3<Float>(ptr[0], ptr[1], ptr[2])
            })

            if let normalData {
                let normalPointer = normalData.dataStart.advanced(by: i * normalData.stride)
                normals.append(normalPointer.withMemoryRebound(to: Float.self, capacity: 3) { ptr in
                    SIMD3<Float>(ptr[0], ptr[1], ptr[2])
                })
            } else {
                normals.append(.zero)
            }
        }

        // Submeshes index directly into the shared vertex buffer above — unlike
        // FootMeshProcessor.fuse(), there's no per-anchor offset to apply here.
        var indices: [UInt32] = []
        let submeshes = (mdlMesh.submeshes as? [MDLSubmesh]) ?? []
        for submesh in submeshes {
            guard submesh.geometryType == .triangles else { continue }
            let map = submesh.indexBuffer.map()
            let count = submesh.indexCount

            switch submesh.indexType {
            case .uInt8:
                let ptr = map.bytes.assumingMemoryBound(to: UInt8.self)
                for i in 0..<count { indices.append(UInt32(ptr[i])) }
            case .uInt16:
                let ptr = map.bytes.assumingMemoryBound(to: UInt16.self)
                for i in 0..<count { indices.append(UInt32(ptr[i])) }
            case .uInt32:
                let ptr = map.bytes.assumingMemoryBound(to: UInt32.self)
                for i in 0..<count { indices.append(ptr[i]) }
            default:
                continue
            }
        }

        return FootMesh(vertices: vertices, normals: normals, triangleIndices: indices)
    }
}
