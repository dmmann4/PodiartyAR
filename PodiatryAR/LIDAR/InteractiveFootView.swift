import SwiftUI
import RealityKit
import simd

/// SwiftUI entry point: pass in the processed mesh once scanning + ML landmark
/// detection are done. Renders an orbitable 3D model with the detected landmarks
/// overlaid as small markers.
struct InteractiveFootView: View {
    let mesh: FootMesh
    let landmarks: FootLandmarks
    let measurements: FootMeasurements

    var body: some View {
        VStack(spacing: 0) {
            FootModelViewer(mesh: mesh, landmarks: landmarks)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 24) {
                measurementLabel("Length", measurements.lengthMM)
                measurementLabel("Width", measurements.widthMM)
                measurementLabel("Arch", measurements.archHeightMM)
            }
            .padding()
        }
    }

    private func measurementLabel(_ name: String, _ mm: Float) -> some View {
        VStack {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.1f mm", mm)).font(.headline)
        }
    }
}

/// UIViewRepresentable wrapping a non-AR RealityKit ARView in "model preview" mode —
/// no camera passthrough, no world tracking, just an orbitable 3D scene. This is the
/// right mode for inspecting a completed scan rather than scanning live.
private struct FootModelViewer: UIViewRepresentable {
    let mesh: FootMesh
    let landmarks: FootLandmarks

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        arView.environment.background = .color(.systemBackground)

        let anchor = AnchorEntity(world: .zero)
        let modelEntity = makeModelEntity()
        anchor.addChild(modelEntity)
        addLandmarkMarkers(to: anchor)
        arView.scene.addAnchor(anchor)

        context.coordinator.modelEntity = modelEntity
        context.coordinator.attachGestures(to: arView)

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeModelEntity() -> ModelEntity {
        var descriptor = MeshDescriptor(name: "foot")
        descriptor.positions = MeshBuffer(mesh.vertices)
        if mesh.normals.contains(where: { $0 != .zero }) {
            descriptor.normals = MeshBuffer(mesh.normals)
        }
        descriptor.primitives = .triangles(mesh.triangleIndices)

        let resource = try! MeshResource.generate(from: [descriptor])
        var material = SimpleMaterial(color: .init(white: 0.85, alpha: 1), isMetallic: false)
        material.roughness = 0.6

        return ModelEntity(mesh: resource, materials: [material])
    }

    private func addLandmarkMarkers(to anchor: AnchorEntity) {
        let points: [(SIMD3<Float>, UIColor)] = [
            (landmarks.heel, .systemRed),
            (landmarks.toeTip, .systemBlue),
            (landmarks.firstMetatarsalHead, .systemGreen),
            (landmarks.fifthMetatarsalHead, .systemGreen),
            (landmarks.archPeak, .systemOrange),
        ]
        for (position, color) in points {
            let marker = ModelEntity(
                mesh: .generateSphere(radius: 0.003),
                materials: [SimpleMaterial(color: color, isMetallic: false)]
            )
            marker.position = position
            anchor.addChild(marker)
        }
    }

    /// Arcball rotation on both axes + pinch-to-scale.
    ///
    /// How the arcball works:
    ///   • On `.began` we snapshot the entity's current orientation quaternion.
    ///   • On each `.changed` tick we read the *total* translation since the gesture
    ///     began (not the delta since last tick — that would accumulate floating-point
    ///     drift on every frame).
    ///   • We convert horizontal drag → a rotation around the world-up Y axis, and
    ///     vertical drag → a rotation around the world-right X axis, using the total
    ///     translation scaled to radians.
    ///   • The two quaternions are composed (yaw first, then pitch) and multiplied
    ///     onto the snapshot orientation so the result is always relative to where the
    ///     gesture started, not to the previous frame's value.
    ///
    /// This gives natural "tumble" behaviour in all directions with no gimbal lock
    /// and no orientation drift across multiple drag gestures.
    final class Coordinator {
        var modelEntity: ModelEntity?
        private var startRotation: simd_quatf = simd_quatf(angle: 0, axis: [0, 1, 0])
        private var startScale: Float = 1

        /// Sensitivity in radians per point of drag.
        private let rotationSensitivity: Float = 0.007

        func attachGestures(to arView: ARView) {
            let pan   = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
            arView.addGestureRecognizer(pan)
            arView.addGestureRecognizer(pinch)
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let entity = modelEntity else { return }

            switch gesture.state {
            case .began:
                // Snapshot the orientation at the start of this gesture. All
                // subsequent .changed ticks compose onto this baseline so there
                // is no per-frame accumulation error.
                startRotation = entity.orientation

            case .changed:
                // Total translation from the gesture's origin (not frame delta).
                let t = gesture.translation(in: gesture.view)

                // Horizontal drag → spin around world Y (yaw).
                let yawAngle   = Float(t.x) * rotationSensitivity
                let yaw        = simd_quatf(angle: yawAngle,  axis: [0, 1, 0])

                // Vertical drag → tilt around world X (pitch).
                // Negative because dragging up (negative t.y in UIKit) should
                // tilt the top of the model toward the viewer.
                let pitchAngle = Float(-t.y) * rotationSensitivity
                let pitch      = simd_quatf(angle: pitchAngle, axis: [1, 0, 0])

                // Apply yaw first, then pitch, onto the snapshotted orientation.
                entity.orientation = simd_normalize(pitch * yaw * startRotation)

            default:
                break
            }
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let entity = modelEntity else { return }

            switch gesture.state {
            case .began:
                startScale = entity.scale.x
            case .changed:
                let newScale = max(0.2, min(5, startScale * Float(gesture.scale)))
                entity.scale = SIMD3(repeating: newScale)
            default:
                break
            }
        }
    }
}
