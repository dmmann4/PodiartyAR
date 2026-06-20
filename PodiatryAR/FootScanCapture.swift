import ARKit
import RealityKit
import simd
import Combine

/// Drives an ARSession configured for LiDAR scene reconstruction and accumulates
/// ARMeshAnchors as the user moves the phone around the foot.
///
/// Requires a LiDAR-equipped device (iPhone 12 Pro+ / iPad Pro 2020+).
final class FootScanCapture: NSObject, ObservableObject, ARSessionDelegate {

    @Published private(set) var isScanning = false
    @Published private(set) var coveragePercent: Double = 0
    @Published private(set) var statusMessage = "Point the camera at the foot"

    let session = ARSession()

    /// Latest mesh anchors keyed by identifier. ARKit updates these continuously as
    /// new geometry is observed — we keep the most recent version of each.
    private var meshAnchors: [UUID: ARMeshAnchor] = [:]

    /// World-space bounding box we expect the foot to occupy, used only to estimate
    /// scan coverage for UI feedback (not for filtering — that happens in
    /// FootMeshProcessor).
    private var expectedBounds: (min: SIMD3<Float>, max: SIMD3<Float>)?

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
    }

    func start() {
        guard Self.isSupported else {
            statusMessage = "This device doesn't have LiDAR — use the photogrammetry capture flow instead"
            return
        }

        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .meshWithClassification
        config.frameSemantics.insert(.sceneDepth)
        config.planeDetection = [.horizontal]

        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])

        meshAnchors.removeAll()
        isScanning = true
        statusMessage = "Slowly circle the foot, keeping it centered"
    }

    func stop() {
        session.pause()
        isScanning = false
        statusMessage = "Scan complete — processing"
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        update(with: anchors)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        update(with: anchors)
    }

    private func update(with anchors: [ARAnchor]) {
        var didChange = false
        for anchor in anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
            meshAnchors[meshAnchor.identifier] = meshAnchor
            didChange = true
        }
        if didChange {
            DispatchQueue.main.async { [weak self] in
                self?.updateCoverageEstimate()
            }
        }
    }

    /// Rough coverage estimate: fraction of a 1-meter cube around the camera's
    /// current focus point that has been observed. Good enough to drive a progress
    /// indicator; not used for any geometric filtering.
    private func updateCoverageEstimate() {
        let totalVertices = meshAnchors.values.reduce(0) { $0 + $1.geometry.vertices.count }
        // Heuristic: a reasonably complete single-foot scan tends to land in the
        // 15k-40k vertex range at default LiDAR resolution. Tune against real scans.
        coveragePercent = min(1.0, Double(totalVertices) / 25_000.0)
        if coveragePercent > 0.85 {
            statusMessage = "Good coverage — you can stop scanning"
        }
    }

    /// Snapshot of the currently accumulated mesh anchors, transformed into world space.
    /// Hand this to FootMeshProcessor once scanning stops.
    func currentMeshAnchors() -> [ARMeshAnchor] {
        Array(meshAnchors.values)
    }
}
