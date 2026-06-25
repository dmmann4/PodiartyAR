import SwiftUI
import ARKit
import SceneKit

// MARK: - AR Preview (SceneKit, settable session)

/// Live camera preview during scanning, with the growing LiDAR mesh drawn as a
/// cyan wireframe overlay.
///
/// Uses ARSCNView (not RealityKit ARView) because ARSCNView.session is settable,
/// letting us share the exact ARSession that FootScanCapture is already running.
///
/// `showSceneUnderstanding` is an ARView/RealityKit-only debug option and does not
/// exist on ARSCNView. Instead, the Coordinator implements ARSCNViewDelegate and
/// manually creates/updates/removes a SCNNode for every ARMeshAnchor, building the
/// wireframe ourselves. This gives identical visual feedback and works correctly with
/// ARSCNView's shared-session architecture.
struct ARScanPreviewView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.delegate = context.coordinator
        view.automaticallyUpdatesLighting = true
        // No debug overlays needed — the delegate draws the mesh itself.
        view.debugOptions = []
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    func makeCoordinator() -> MeshOverlayCoordinator { MeshOverlayCoordinator() }
}

// MARK: - Mesh wireframe coordinator

/// Maintains a SCNNode per ARMeshAnchor UUID and rebuilds each node's geometry
/// whenever ARKit delivers an updated anchor. The wireframe material uses
/// fillMode = .lines so every triangle edge is visible against the camera feed
/// without obscuring it.
final class MeshOverlayCoordinator: NSObject, ARSCNViewDelegate {

    // One node per anchor identifier — ARKit can update the same anchor many
    // times as new geometry is observed, so we replace rather than accumulate.
    private var meshNodes: [UUID: SCNNode] = [:]

    // Shared wireframe material — created once, referenced by every node.
    private let wireframeMaterial: SCNMaterial = {
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.systemCyan.withAlphaComponent(0.80)
        mat.fillMode = .lines          // triangle edges only, no fill
        mat.isDoubleSided = true
        mat.lightingModel = .constant  // unaffected by scene lighting
        return mat
    }()

    // MARK: ARSCNViewDelegate — anchor lifecycle

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        let meshNode = buildMeshNode(from: meshAnchor)
        meshNodes[meshAnchor.identifier] = meshNode
        node.addChildNode(meshNode)
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        // Remove the old node for this anchor and replace with refreshed geometry.
        meshNodes[meshAnchor.identifier]?.removeFromParentNode()
        let meshNode = buildMeshNode(from: meshAnchor)
        meshNodes[meshAnchor.identifier] = meshNode
        node.addChildNode(meshNode)
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        meshNodes[meshAnchor.identifier]?.removeFromParentNode()
        meshNodes.removeValue(forKey: meshAnchor.identifier)
    }

    // MARK: Geometry construction

    /// Converts one ARMeshAnchor into a SCNNode with wireframe geometry.
    /// ARMeshAnchor geometry is in anchor-local space; the parent SCNNode that
    /// ARSCNView creates for each anchor already carries the anchor's world transform,
    /// so we don't apply it here.
    private func buildMeshNode(from anchor: ARMeshAnchor) -> SCNNode {
        let geometry = anchor.geometry

        // ── Vertices ──────────────────────────────────────────────────────────
        let vertexCount = geometry.vertices.count
        var positions = [SCNVector3]()
        positions.reserveCapacity(vertexCount)
        for i in 0..<vertexCount {
            let v = geometry.vertex(at: UInt32(i))
            positions.append(SCNVector3(v.x, v.y, v.z))
        }
        let vertexSource = SCNGeometrySource(vertices: positions)

        // ── Indices (triangles) ───────────────────────────────────────────────
        let faceCount = geometry.faces.count
        let indicesPerFace = geometry.faces.indexCountPerPrimitive   // always 3
        var indices = [Int32]()
        indices.reserveCapacity(faceCount * indicesPerFace)
        for f in 0..<faceCount {
            let faceIndices = geometry.vertexIndices(ofFaceAt: f)
            for idx in faceIndices { indices.append(Int32(idx)) }
        }
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: faceCount,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        let scnGeometry = SCNGeometry(sources: [vertexSource], elements: [element])
        scnGeometry.materials = [wireframeMaterial]

        return SCNNode(geometry: scnGeometry)
    }
}

// MARK: - Coverage ring overlay

/// An animated ring that fills clockwise as `progress` goes 0 → 1.
/// Turns green once coverage crosses 85 % to signal "enough geometry captured".
struct CoverageRingView: View {
    let progress: Double          // 0.0 – 1.0

    private var ringColor: Color {
        progress > 0.85 ? .green : .white
    }

    var body: some View {
        ZStack {
            // Track
            Circle()
                .stroke(Color.white.opacity(0.25), lineWidth: 6)

            // Fill
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: progress)

            // Percentage label
            Text("\(Int(progress * 100))%")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(ringColor)
                .animation(.easeInOut(duration: 0.3), value: progress)
        }
        .frame(width: 64, height: 64)
    }
}

// MARK: - Scanning zone guide

/// A semi-transparent oval "footprint" guide drawn in the centre of the screen
/// to show users where to position the foot in frame. Pulses slowly to draw
/// attention without being distracting.
struct FootGuideOverlay: View {
    @State private var pulsing = false

    var body: some View {
        Ellipse()
            .stroke(
                Color.white.opacity(pulsing ? 0.55 : 0.25),
                style: StrokeStyle(lineWidth: 2, dash: [8, 6])
            )
            .frame(width: 160, height: 260)
            .scaleEffect(pulsing ? 1.03 : 1.0)
            .animation(
                .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
    }
}

// MARK: - Scanning phase chips

/// Small chip badges shown across the top of the screen indicating which
/// parts of the foot still need coverage.
private struct ScanPhaseChip: View {
    let label: String
    let done: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dotted")
                .imageScale(.small)
            Text(label)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(done ? Color.green : Color.white.opacity(0.7))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(Color.black.opacity(0.45))
        )
    }
}

// MARK: - Main ScanningView

struct ScanningView: View {
    @ObservedObject var capture: FootScanCapture
    let onFinish: () -> Void

    // Three coarse zones to coach through; driven by overall coverage buckets.
    private var topDone:   Bool { capture.coveragePercent > 0.30 }
    private var sidesDone: Bool { capture.coveragePercent > 0.60 }
    private var archDone:  Bool { capture.coveragePercent > 0.85 }

    var body: some View {
        ZStack {
            // ── AR camera feed with live mesh wireframe ───────────────────────
            ARScanPreviewView(session: capture.session)
                .ignoresSafeArea()

            // ── Foot positioning guide (centre of frame) ──────────────────────
            FootGuideOverlay()
                .offset(y: -20)

            // ── Zone-progress chips (top) ─────────────────────────────────────
            VStack {
                HStack(spacing: 8) {
                    ScanPhaseChip(label: "Top",   done: topDone)
                    ScanPhaseChip(label: "Sides", done: sidesDone)
                    ScanPhaseChip(label: "Arch",  done: archDone)
                }
                .padding(.top, 16)
                Spacer()
            }

            // ── Bottom HUD ────────────────────────────────────────────────────
            VStack {
                Spacer()

                VStack(spacing: 16) {
                    HStack(spacing: 16) {
                        CoverageRingView(progress: capture.coveragePercent)

                        Text(capture.statusMessage)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 24)

                    Button(action: onFinish) {
                        Text("Done scanning")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(capture.coveragePercent > 0.85
                                        ? Color.green
                                        : Color.white.opacity(0.9))
                            .foregroundStyle(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .animation(.easeInOut(duration: 0.3), value: capture.coveragePercent)
                    }
                    .padding(.horizontal, 32)
                }
                .padding(.vertical, 20)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.75)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                )
            }
        }
    }
}
