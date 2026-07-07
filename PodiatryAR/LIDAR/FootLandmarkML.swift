import CoreML
import simd

/// Anatomical points an orthotist actually cares about.
struct FootLandmarks {
    let heel: SIMD3<Float>
    let toeTip: SIMD3<Float>
    let firstMetatarsalHead: SIMD3<Float>
    let fifthMetatarsalHead: SIMD3<Float>
    let archPeak: SIMD3<Float>
}

enum FootLandmarkPredictor {

    /// Fixed input size expected by the trained model. 2048 points is a common
    /// PointNet-style input size — adjust to match however you train it.
    static let sampleCount = 2048

    /// Predicts landmarks using a trained Core ML model if one is bundled, otherwise
    /// falls back to pure geometry so the rest of the app works before training.
    static func predict(mesh: FootMesh) -> FootLandmarks {
        let sampled = farthestPointSample(mesh.vertices, count: sampleCount)

        if let model = try? FootLandmarkModelWrapper() {
            do {
                return try model.predict(points: sampled)
            } catch {
                // Fall through to the geometric heuristic if inference fails —
                // never block the user on a model error.
            }
        }

        return geometricFallback(mesh: mesh)
    }

    // MARK: - Sampling

    /// Farthest-point sampling: greedily picks points that maximize distance from
    /// the already-selected set, producing a fixed-size, well-distributed point
    /// cloud regardless of how dense the source mesh is.
    static func farthestPointSample(_ points: [SIMD3<Float>], count: Int) -> [SIMD3<Float>] {
        guard points.count > count else { return points }

        var selected: [SIMD3<Float>] = [points[0]]
        var minDistances = points.map { simd_distance_squared($0, points[0]) }

        while selected.count < count {
            guard let farthestIndex = minDistances.indices.max(by: { minDistances[$0] < minDistances[$1] }) else { break }
            let next = points[farthestIndex]
            selected.append(next)
            for i in points.indices {
                let d = simd_distance_squared(points[i], next)
                if d < minDistances[i] { minDistances[i] = d }
            }
            minDistances[farthestIndex] = -1 // never reselect
        }

        return selected
    }

    // MARK: - Geometric fallback (no trained model required)

    private static func geometricFallback(mesh: FootMesh) -> FootLandmarks {
        let measurements = FootMeshProcessor.boundingMeasurements(mesh)
        let centroid = mesh.vertices.reduce(SIMD3<Float>.zero, +) / Float(mesh.vertices.count)

        // Crude axis-aligned heuristics: longest extent = heel-to-toe, the floor
        // points at either end are heel/toe, and the highest point near the
        // midpoint is treated as the arch peak. Replace with the trained model
        // for real accuracy — this exists only so the pipeline runs end-to-end.
        let sortedByZ = mesh.vertices.sorted { $0.z < $1.z }
        let heel = sortedByZ.first ?? centroid
        let toeTip = sortedByZ.last ?? centroid

        let sortedByX = mesh.vertices.sorted { $0.x < $1.x }
        let firstMT = sortedByX.first ?? centroid
        let fifthMT = sortedByX.last ?? centroid

        let archCandidates = mesh.vertices.filter {
            abs($0.z - centroid.z) < measurements.lengthMM / 1000 * 0.15
        }
        let archPeak = archCandidates.max(by: { $0.y < $1.y }) ?? centroid

        return FootLandmarks(
            heel: heel, toeTip: toeTip,
            firstMetatarsalHead: firstMT, fifthMetatarsalHead: fifthMT,
            archPeak: archPeak
        )
    }
}

/// Thin wrapper around a trained Core ML model. Train a PointNet/PointNet++-style
/// regressor (input: Nx3 point cloud, output: 5x3 landmark coordinates) with
/// PyTorch + coremltools, or with Create ML if you adapt it to a tabular regression
/// task. Drop the resulting FootLandmarkModel.mlpackage into the Xcode project —
/// Xcode auto-generates this wrapper's underlying class.
private struct FootLandmarkModelWrapper {
    private let model: MLModel

    init() throws {
        // Replace with the generated class once you've added a trained model,
        // e.g.: model = try FootLandmarkModel(configuration: .init()).model
        guard let url = Bundle.main.url(forResource: "FootLandmarkModel", withExtension: "mlmodelc") else {
            throw CocoaError(.fileNoSuchFile)
        }
        model = try MLModel(contentsOf: url)
    }

    func predict(points: [SIMD3<Float>]) throws -> FootLandmarks {
        let inputArray = try MLMultiArray(shape: [1, NSNumber(value: points.count), 3], dataType: .float32)
        for (i, p) in points.enumerated() {
            inputArray[[0, NSNumber(value: i), 0]] = NSNumber(value: p.x)
            inputArray[[0, NSNumber(value: i), 1]] = NSNumber(value: p.y)
            inputArray[[0, NSNumber(value: i), 2]] = NSNumber(value: p.z)
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: ["points": inputArray])
        let output = try model.prediction(from: provider)

        guard let landmarks = output.featureValue(for: "landmarks")?.multiArrayValue else {
            throw CocoaError(.coderInvalidValue)
        }

        func point(_ row: Int) -> SIMD3<Float> {
            SIMD3(
                landmarks[[0, NSNumber(value: row), 0]].floatValue,
                landmarks[[0, NSNumber(value: row), 1]].floatValue,
                landmarks[[0, NSNumber(value: row), 2]].floatValue
            )
        }

        return FootLandmarks(
            heel: point(0), toeTip: point(1),
            firstMetatarsalHead: point(2), fifthMetatarsalHead: point(3),
            archPeak: point(4)
        )
    }
}
