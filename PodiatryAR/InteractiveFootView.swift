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

    /// Pan rotates the model around its vertical axis, pinch scales it. Both act
    /// directly on the entity transform since there's no AR world to move a camera
    /// through in non-AR mode.
    final class Coordinator {
        var modelEntity: ModelEntity?
        private var startRotation: simd_quatf = simd_quatf(angle: 0, axis: [0, 1, 0])
        private var startScale: Float = 1

        func attachGestures(to arView: ARView) {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
            arView.addGestureRecognizer(pan)
            arView.addGestureRecognizer(pinch)
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let entity = modelEntity else { return }
            switch gesture.state {
            case .began:
                startRotation = entity.orientation
            case .changed:
                let translation = gesture.translation(in: gesture.view)
                let angle = Float(translation.x) * 0.005
                let spin = simd_quatf(angle: angle, axis: [0, 1, 0])
                entity.orientation = spin * startRotation
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
