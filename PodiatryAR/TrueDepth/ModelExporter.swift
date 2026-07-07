import Foundation
import SceneKit
import simd

enum ModelExporter {

    enum ExportError: Error {
        case writeFailed
    }

    // MARK: - OBJ (widely supported, human-readable)

    static func exportOBJ(mesh: ScanMesh, to url: URL) throws {
        var text = "# Exported foot scan\n"
        for v in mesh.vertices {
            text += "v \(v.x) \(v.y) \(v.z)\n"
        }
        for n in mesh.normals {
            text += "vn \(n.x) \(n.y) \(n.z)\n"
        }
        var i = 0
        while i < mesh.triangleIndices.count {
            // OBJ indices are 1-based, and "index//index" ties vertex+normal together.
            let a = mesh.triangleIndices[i] + 1
            let b = mesh.triangleIndices[i + 1] + 1
            let c = mesh.triangleIndices[i + 2] + 1
            text += "f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n"
            i += 3
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Binary STL (near-universal input for slicers / orthotic CAD / print services)

    static func exportSTL(mesh: ScanMesh, to url: URL) throws {
        var data = Data()

        // 80-byte header, unused.
        data.append(Data(repeating: 0, count: 80))

        var triangleCount = UInt32(mesh.triangleIndices.count / 3)
        data.append(Data(bytes: &triangleCount, count: 4))

        var i = 0
        while i < mesh.triangleIndices.count {
            let ia = Int(mesh.triangleIndices[i])
            let ib = Int(mesh.triangleIndices[i + 1])
            let ic = Int(mesh.triangleIndices[i + 2])

            let a = mesh.vertices[ia], b = mesh.vertices[ib], c = mesh.vertices[ic]
            var normal = simd_normalize(simd_cross(b - a, c - a))
            if !normal.x.isFinite || !normal.y.isFinite || !normal.z.isFinite {
                normal = SIMD3<Float>(0, 0, 0)
            }

            appendVec3(normal, to: &data)
            appendVec3(a, to: &data)
            appendVec3(b, to: &data)
            appendVec3(c, to: &data)

            var attributeByteCount: UInt16 = 0
            data.append(Data(bytes: &attributeByteCount, count: 2))

            i += 3
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed
        }
    }

    private static func appendVec3(_ v: SIMD3<Float>, to data: inout Data) {
        var x = v.x, y = v.y, z = v.z
        data.append(Data(bytes: &x, count: 4))
        data.append(Data(bytes: &y, count: 4))
        data.append(Data(bytes: &z, count: 4))
    }

    // MARK: - PLY (raw point cloud, useful for feeding an offline reconstruction pipeline)

    static func exportPLY(points: [SIMD3<Float>], to url: URL) throws {
        var text = """
        ply
        format ascii 1.0
        element vertex \(points.count)
        property float x
        property float y
        property float z
        end_header
        
        """
        for p in points {
            text += "\(p.x) \(p.y) \(p.z)\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - USDZ (for AR Quick Look / in-app preview sharing)

    static func exportUSDZ(scene: SCNScene, to url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        scene.write(to: url, options: nil, delegate: nil) { totalProgress, error, stop in
            if let error = error {
                completion(.failure(error))
                stop.pointee = true
            } else if totalProgress >= 1.0 {
                completion(.success(url))
            }
        }
    }

    // MARK: - Convenience: build an SCNGeometry from a ScanMesh for display/export

    static func makeSCNGeometry(from mesh: ScanMesh) -> SCNGeometry {
        let vertexSource = SCNGeometrySource(vertices: mesh.vertices.map { SCNVector3($0.x, $0.y, $0.z) })
        let normalSource = SCNGeometrySource(normals: mesh.normals.map { SCNVector3($0.x, $0.y, $0.z) })
        var sources = [vertexSource, normalSource]

        // When the capture has a color for every vertex, hand it to SceneKit
        // as a genuine per-vertex color source rather than falling back to a
        // flat material — this is what makes the reviewed model look like an
        // actual photo of the scanned skin instead of a uniform clay color.
        let hasVertexColor = (mesh.vertexColors?.count ?? 0) == mesh.vertices.count && !mesh.vertices.isEmpty
        if hasVertexColor, let vertexColors = mesh.vertexColors {
            var colorData = Data()
            colorData.reserveCapacity(vertexColors.count * MemoryLayout<Float>.size * 4)
            for c in vertexColors {
                var r = c.x, g = c.y, b = c.z, a: Float = 1.0
                colorData.append(Data(bytes: &r, count: MemoryLayout<Float>.size))
                colorData.append(Data(bytes: &g, count: MemoryLayout<Float>.size))
                colorData.append(Data(bytes: &b, count: MemoryLayout<Float>.size))
                colorData.append(Data(bytes: &a, count: MemoryLayout<Float>.size))
            }
            let colorSource = SCNGeometrySource(data: colorData,
                                                 semantic: .color,
                                                 vectorCount: vertexColors.count,
                                                 usesFloatComponents: true,
                                                 componentsPerVector: 4,
                                                 bytesPerComponent: MemoryLayout<Float>.size,
                                                 dataOffset: 0,
                                                 dataStride: MemoryLayout<Float>.size * 4)
            sources.append(colorSource)
        }

        let element = SCNGeometryElement(indices: mesh.triangleIndices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: sources, elements: [element])

        let material = SCNMaterial()
        if hasVertexColor {
            // White diffuse so the vertex color source is what shows,
            // unmultiplied by any tint.
            material.diffuse.contents = UIColorCompat.white
            material.lightingModel = .physicallyBased
            material.roughness.contents = 0.55
        } else {
            material.diffuse.contents = UIColorCompat.scanSurfaceColor
        }
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }
}

// Small shim so this file doesn't hard-depend on UIKit vs AppKit at the top.
#if canImport(UIKit)
import UIKit
enum UIColorCompat {
    static let scanSurfaceColor: UIColor = UIColor(red: 0.85, green: 0.78, blue: 0.70, alpha: 1.0)
    static let white: UIColor = .white
}
#else
import AppKit
enum UIColorCompat {
    static let scanSurfaceColor: NSColor = NSColor(red: 0.85, green: 0.78, blue: 0.70, alpha: 1.0)
    static let white: NSColor = .white
}
#endif
