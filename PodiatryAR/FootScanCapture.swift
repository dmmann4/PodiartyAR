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
        statusMessage = "Place foot inside the oval, then slowly circle around it"
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

    /// Vertex-count-based coverage estimate with coaching messages that change
    /// as the user progresses through the scan.
    ///
    /// Thresholds are tuned empirically for a typical single-foot LiDAR scan
    /// at default ARKit mesh resolution (~25 k vertices for good coverage).
    /// Adjust after profiling real scans on your target devices.
    private func updateCoverageEstimate() {
        let totalVertices = meshAnchors.values.reduce(0) { $0 + $1.geometry.vertices.count }
        let raw = min(1.0, Double(totalVertices) / 25_000.0)

        // Smooth the progress bar so it doesn't jump around as anchors update
        coveragePercent = coveragePercent + (raw - coveragePercent) * 0.4

        switch coveragePercent {
        case ..<0.15:
            statusMessage = "Place the foot inside the oval and move closer"
        case 0.15..<0.35:
            statusMessage = "Good start — slowly circle around the top of the foot"
        case 0.35..<0.60:
            statusMessage = "Keep going — tilt down to capture the sides and sole"
        case 0.60..<0.85:
            statusMessage = "Almost there — scan the arch and heel area"
        default:
            statusMessage = "Great coverage — tap Done when ready"
        }
    }

    /// Snapshot of the currently accumulated mesh anchors.
    /// Hand this to FootMeshProcessor once scanning stops.
    func currentMeshAnchors() -> [ARMeshAnchor] {
        Array(meshAnchors.values)
    }
}
