import ModelIO
import simd

enum MeshExportError: Error {
    case assetExportFailed
}

enum MeshExporter {

    // MARK: - USDZ / OBJ via Model I/O

    /// USDZ is convenient for sharing/AR Quick Look previews. OBJ is widely accepted
    /// by CAD/CAM tooling. Model I/O handles both natively from an MDLAsset.
    static func exportUSDZ(_ mesh: FootMesh, to url: URL) throws {
        try export(mesh, to: url)
    }

    static func exportOBJ(_ mesh: FootMesh, to url: URL) throws {
        try export(mesh, to: url)
    }

    private static func export(_ mesh: FootMesh, to url: URL) throws {
        let allocator = MDLMeshBufferDataAllocator()

        let positionData = Data(bytes: mesh.vertices, count: mesh.vertices.count * MemoryLayout<SIMD3<Float>>.stride)
        let positionBuffer = allocator.newBuffer(with: positionData, type: .vertex)

        let indexData = Data(bytes: mesh.triangleIndices, count: mesh.triangleIndices.count * MemoryLayout<UInt32>.stride)
        let indexBuffer = allocator.newBuffer(with: indexData, type: .index)

        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0
        )
        vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)

        let submesh = MDLSubmesh(
            indexBuffer: indexBuffer,
            indexCount: mesh.triangleIndices.count,
            indexType: .uInt32,
            geometryType: .triangles,
            material: nil
        )

        let mdlMesh = MDLMesh(
            vertexBuffer: positionBuffer,
            vertexCount: mesh.vertices.count,
            descriptor: vertexDescriptor,
            submeshes: [submesh]
        )
        mdlMesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)

        let asset = MDLAsset()
        asset.add(mdlMesh)

        guard MDLAsset.canExportFileExtension(url.pathExtension) else {
            throw MeshExportError.assetExportFailed
        }
        try asset.export(to: url)
    }

    // MARK: - STL (manual binary writer)

    /// Model I/O doesn't write STL, but it's the format most orthotic manufacturers
    /// and 3D-printing pipelines expect. Binary STL format: 80-byte header,
    /// 4-byte triangle count, then per triangle: 12 bytes normal + 3x12 bytes
    /// vertices + 2-byte attribute byte count, all little-endian.
    static func exportSTL(_ mesh: FootMesh, to url: URL) throws {
        var data = Data(count: 80) // header, left blank
        var triangleCount = UInt32(mesh.triangleIndices.count / 3)
        data.append(Data(bytes: &triangleCount, count: 4))

        var i = 0
        while i < mesh.triangleIndices.count {
            let a = mesh.vertices[Int(mesh.triangleIndices[i])]
            let b = mesh.vertices[Int(mesh.triangleIndices[i + 1])]
            let c = mesh.vertices[Int(mesh.triangleIndices[i + 2])]

            var normal = simd_normalize(simd_cross(b - a, c - a))
            if normal.x.isNaN || normal.y.isNaN || normal.z.isNaN {
                normal = SIMD3(0, 0, 0)
            }

            appendFloat3(normal, to: &data)
            appendFloat3(a, to: &data)
            appendFloat3(b, to: &data)
            appendFloat3(c, to: &data)

            var attributeByteCount: UInt16 = 0
            data.append(Data(bytes: &attributeByteCount, count: 2))

            i += 3
        }

        try data.write(to: url)
    }

    private static func appendFloat3(_ v: SIMD3<Float>, to data: inout Data) {
        var x = v.x, y = v.y, z = v.z
        data.append(Data(bytes: &x, count: 4))
        data.append(Data(bytes: &y, count: 4))
        data.append(Data(bytes: &z, count: 4))
    }
}
