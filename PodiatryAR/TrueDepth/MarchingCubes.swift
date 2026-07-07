//
//  MarchingCubes.swift
//  PodiatryAR
//
//  Created by Mann Fam on 7/1/26.
//


//final class MarchingCubes {
//    struct Vertex { var position: Float3; var normal: Float3 }
//    struct Mesh { var vertices: [Vertex]; var indices: [UInt32] }
//
//    // Basic CPU marching cubes. For brevity, edge table and tri table are omitted here.
//    // Use standard tables from Paul Bourke or other references.
//    func extractMesh(tsdf: [Float], weight: [Float], dimX: Int, dimY: Int, dimZ: Int, voxelSize: Float, origin: Float3, iso: Float = 0.0) -> Mesh {
//        var vertices = [Vertex]()
//        var indices = [UInt32]()
//        // iterate cells
//        for z in 0..<(dimZ - 1) {
//            for y in 0..<(dimY - 1) {
//                for x in 0..<(dimX - 1) {
//                    // sample 8 corners
//                    var cornerVals = [Float](repeating: 1.0, count: 8)
//                    var cornerPos = [Float3](repeating: Float3(0,0,0), count: 8)
//                    for i in 0..<8 {
//                        let cx = x + ((i & 1) != 0 ? 1 : 0)
//                        let cy = y + ((i & 2) != 0 ? 1 : 0)
//                        let cz = z + ((i & 4) != 0 ? 1 : 0)
//                        let idx = (cz * dimY + cy) * dimX + cx
//                        cornerVals[i] = tsdf[idx]
//                        cornerPos[i] = origin + Float3((Float(cx)+0.5)*voxelSize, (Float(cy)+0.5)*voxelSize, (Float(cz)+0.5)*voxelSize)
//                    }
//                    // compute cube index
//                    var cubeIndex = 0
//                    for i in 0..<8 { if cornerVals[i] < iso { cubeIndex |= (1 << i) } }
//                    if cubeIndex == 0 || cubeIndex == 255 { continue }
//                    // lookup edges and triangles using tables (not included here)
//                    // for each triangle, interpolate vertices and compute normals
//                    // append to vertices and indices
//                }
//            }
//        }
//        return Mesh(vertices: vertices, indices: indices)
//    }
//}
