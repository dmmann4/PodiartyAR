//import SwiftUI
//import SceneKit
//import AVFoundation
//import CoreVideo
//import Combine
//import StandardCyborgFusion
//
//@MainActor
//final class FootScanViewModel: ObservableObject {
//
//    enum ScanState: Equatable {
//        case idle
//        case requestingPermission
//        case scanning
//        case reconstructing
//        case reviewing
//        case error(String)
//    }
//
//    @Published var state: ScanState = .idle
//    @Published var capturedFrameCount: Int = 0
//    @Published var captureProgress: Float = 0
//    @Published var scene = SCNScene()
//    
//    @Published var showScanner = false
//    @Published var showPreview = false
//    @Published var lastSceneThumbnail: UIImage?
//    @Published var lastScene: SCScene?
//    
//    // MARK: - File URLs
//    private var documentsURL: URL {
//        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
//    }
//
//    private var sceneGltfURL: URL {
//        documentsURL.appendingPathComponent("scene.gltf")
//    }
//
//    private var sceneThumbnailURL: URL {
//        documentsURL.appendingPathComponent("scene.png")
//    }
//
//    /// The most recent frame's own unprojected points, refreshed on its own
//    /// (faster) throttle purely for the live "AR dots on the object" overlay
//    /// in FootScanView.
//    @Published var liveOverlay: LiveOverlaySnapshot?
//
//    /// Live per-region scan-completeness wash (yellow -> white), refreshed
//    /// on the same throttle as `liveOverlay`. See `CoverageOverlaySnapshot`.
//    @Published var coverageOverlay: CoverageOverlaySnapshot?
//
//    /// Exposed so the view can show a live full-screen camera preview
//    /// while scanning is in progress.
//    var cameraSession: AVCaptureSession { captureManager.session }
//
//    private let captureManager = TrueDepthCaptureManager()
//
//    /// Fast, single-viewpoint capture: the phone stays still, and this just
//    /// temporally-averages incoming depth frames — no ICP, no walk-around
//    /// sweep. See `FrontSurfaceCapture` in PointCloudProcessing.swift.
//    private let frontCapture = FrontSurfaceCapture()
//    private var currentMesh: ScanMesh?
//    private var currentPoints: [SIMD3<Float>] = []
//
//    // A capture this short doesn't need throttling down for cost the way a
//    // long ICP-merge scan did — every frame in the window is cheap to fold
//    // into the running average — but the overlay is still throttled a touch
//    // so SwiftUI isn't asked to redraw at full camera frame rate.
//    private var lastOverlayTime: TimeInterval = 0
//    private let overlayInterval: TimeInterval = 0.1
//
//    /// How long to hold still for. This is the whole reason capture feels
//    /// instant: there's no coverage/rotation target to hit, just a short
//    /// fixed window to average away sensor noise.
//    private let captureDuration: TimeInterval = 1.2
//    private var captureStartTime: TimeInterval?
//
//    init() {
//        captureManager.delegate = self
//    }
//
//    public func saveScene(scene: SCScene, thumbnail: UIImage?) {
//        scene.writeToGLTF(atPath: sceneGltfURL.path)
//
//        if let thumbnail, let png = thumbnail.pngData() {
//            try? png.write(to: sceneThumbnailURL)
//        }
//    }
//    
//    public func deleteScene() {
//        let fm = FileManager.default
//
//        if fm.fileExists(atPath: sceneGltfURL.path) {
//            try? fm.removeItem(at: sceneGltfURL)
//        }
//        if fm.fileExists(atPath: sceneThumbnailURL.path) {
//            try? fm.removeItem(at: sceneThumbnailURL)
//        }
//    }
//    
//    func startScanning() {
//        state = .requestingPermission
//        capturedFrameCount = 0
//        captureProgress = 0
//        liveOverlay = nil
//        coverageOverlay = nil
//        captureStartTime = nil
//        showScanner = true
//    }
//
//    /// Called automatically once `captureDuration` has elapsed (from the
//    /// capture delegate below), mirroring the reference app's "hold still
//    /// for a moment and it just finishes" pacing rather than requiring the
//    /// user to notice a coverage bar has filled up and tap a button.
//    private func finishCapture() {
//        guard state == .scanning else { return }
//        captureManager.stop()
//        liveOverlay = nil
//        coverageOverlay = nil
//        state = .reconstructing
//
//        Task.detached(priority: .userInitiated) { [weak self] in
//            guard let self else { return }
//            guard let result = await self.frontCapture.finish() else {
//                await MainActor.run { self.state = .error("Couldn't get a clear view of your hand — make sure your whole hand, wrist to fingertips, stays in frame and try again.") }
//                return
//            }
//            let mesh = await FrontSurfaceMesher.reconstruct(depthGrid: result.depthGrid,
//                                                       colorGrid: result.colorGrid,
//                                                       gridWidth: result.gridWidth,
//                                                       gridHeight: result.gridHeight,
//                                                       strideVal: result.strideVal,
//                                                       intrinsics: result.intrinsics)
//            await MainActor.run {
//                self.currentMesh = mesh
//                self.currentPoints = result.frame.points
//                self.updateScene(with: mesh)
//                self.state = .reviewing
//            }
//        }
//    }
//
//    private func updateScene(with mesh: ScanMesh) {
//        let newScene = SCNScene()
//        let geometry = ModelExporter.makeSCNGeometry(from: mesh)
//        let node = SCNNode(geometry: geometry)
//        newScene.rootNode.addChildNode(node)
//
//        let light = SCNNode()
//        light.light = SCNLight()
//        light.light?.type = .omni
//        light.position = SCNVector3(0, 0.3, 0.3)
//        newScene.rootNode.addChildNode(light)
//        newScene.rootNode.addChildNode({
//            let ambient = SCNNode()
//            ambient.light = SCNLight()
//            ambient.light?.type = .ambient
//            ambient.light?.intensity = 300
//            return ambient
//        }())
//
//        self.scene = newScene
//    }
//
//    // MARK: - Export
//
//    func exportSTL() throws -> URL {
//        guard let mesh = currentMesh else { throw ModelExporter.ExportError.writeFailed }
//        let url = FileManager.default.temporaryDirectory.appendingPathComponent("foot_scan.stl")
//        try ModelExporter.exportSTL(mesh: mesh, to: url)
//        return url
//    }
//
//    func exportOBJ() throws -> URL {
//        guard let mesh = currentMesh else { throw ModelExporter.ExportError.writeFailed }
//        let url = FileManager.default.temporaryDirectory.appendingPathComponent("foot_scan.obj")
//        try ModelExporter.exportOBJ(mesh: mesh, to: url)
//        return url
//    }
//
//    func exportRawPointCloudPLY() async throws -> URL {
//        let url = FileManager.default.temporaryDirectory.appendingPathComponent("foot_scan_points.ply")
//        try ModelExporter.exportPLY(points: currentPoints, to: url)
//        return url
//    }
//
//    func exportUSDZ(completion: @escaping (Result<URL, Error>) -> Void) {
//        let url = FileManager.default.temporaryDirectory.appendingPathComponent("foot_scan.usdz")
//        ModelExporter.exportUSDZ(scene: scene, to: url, completion: completion)
//    }
//}
//
//extension FootScanViewModel: TrueDepthCaptureManagerDelegate {
//
//    nonisolated func captureManager(_ manager: TrueDepthCaptureManager, didCapture frame: CapturedFrame) {
//        // Runs off the main actor: folding a frame into FrontSurfaceCapture's
//        // running average (an actor, so this is already safely serialized)
//        // and, occasionally, unprojecting a frame for the live overlay are
//        // both cheap compared to the old ICP merge step, but there's no
//        // reason to make SwiftUI rendering wait on them either.
//        Task.detached(priority: .userInitiated) { [weak self] in
//            guard let self else { return }
//
//            let (isScanning, startTime, overlayDue) = await MainActor.run { () -> (Bool, TimeInterval, Bool) in
//                guard self.state == .scanning else { return (false, 0, false) }
//                if self.captureStartTime == nil { self.captureStartTime = frame.timestamp }
//                let due = frame.timestamp - self.lastOverlayTime >= self.overlayInterval
//                if due { self.lastOverlayTime = frame.timestamp }
//                return (true, self.captureStartTime ?? frame.timestamp, due)
//            }
//            guard isScanning else { return }
//
//            // Crop to just the hand before folding this frame into the
//            // running average. VNDetectHumanHandPoseRequest gives real
//            // "this is a hand, stop at the wrist" landmarks — wrist +
//            // finger joints — which plain depth continuity can't provide,
//            // since the forearm is physically the same continuous surface
//            // as the hand. See HandRegionDetector / FrontSurfaceCapture for
//            // the coordinate-space details.
//            //
//            // If no hand is detected in this particular frame (motion blur,
//            // hand briefly leaving frame, etc.), the frame is simply skipped
//            // rather than folded in uncropped — losing one frame out of the
//            // averaging window is harmless; folding in even one uncropped
//            // frame would let the forearm back in.
//            let framesSoFar = await self.frontCapture.framesAccumulated
//
//            var overlaySnapshot: LiveOverlaySnapshot?
//            var coverageSnapshot: CoverageOverlaySnapshot?
//            if overlayDue {
//                let cloudFrame = PointCloudUnprojector.unproject(depthMap: frame.depthMap,
//                                                                  intrinsics: frame.cameraIntrinsics)
//                if !cloudFrame.points.isEmpty {
//                    overlaySnapshot = LiveOverlaySnapshot(points: cloudFrame.points,
//                                                           intrinsics: frame.cameraIntrinsics,
//                                                           depthWidth: CVPixelBufferGetWidth(frame.depthMap),
//                                                           depthHeight: CVPixelBufferGetHeight(frame.depthMap))
//                }
//                // Same throttle as the point overlay above — this is a UI
//                // refresh, not something that needs to run at full frame rate.
//                coverageSnapshot = await self.frontCapture.coverageSnapshot()
//            }
//
//            let elapsed = frame.timestamp - startTime
//            await MainActor.run {
//                self.captureProgress = min(Float(elapsed / self.captureDuration), 1.0)
//                self.capturedFrameCount = framesSoFar
//                if let overlaySnapshot { self.liveOverlay = overlaySnapshot }
//                if let coverageSnapshot { self.coverageOverlay = coverageSnapshot }
//                if elapsed >= self.captureDuration {
//                    self.finishCapture()
//                }
//            }
//        }
//    }
//
//    nonisolated func captureManager(_ manager: TrueDepthCaptureManager, didFailWithError error: Error) {
//        Task { @MainActor in
//            self.state = .error(error.localizedDescription)
//        }
//    }
//}
//
//struct FootScanView: View {
//    @StateObject private var viewModel = FootScanViewModel()
//    @State private var exportError: String?
//
//    var body: some View {
//        ZStack {
//            // Background layer fills the entire screen regardless of state:
//            // live camera feed while scanning, the reconstructed model while
//            // reviewing, and plain black otherwise.
//            backgroundLayer
//                .ignoresSafeArea()
//
//            VStack {
//                topOverlay
//                Spacer()
//                bottomOverlay
//            }
//            .padding()
//        }
////        .fullScreenCover(isPresented: $viewModel.showScanner) {
////            ScanningViewControllerWrapper(
////                onCancel: { viewModel.showScanner = false },
////                onScan: handleScanCompleted
////            )
////        }
////        .fullScreenCover(isPresented: $viewModel.showPreview) {
////            if let scene = viewModel.lastScene {
////                ScenePreviewWrapper(
////                    scene: scene,
////                    onDelete: viewModel.deleteScene,
////                    onDismiss: { viewModel.showPreview = false },
////                    onSave: { scene, thumbnail in
////                        viewModel.saveScene(scene: scene, thumbnail: thumbnail)
////                        
////                        viewModel.showPreview = false
////                        viewModel.state = .idle
////                    }
////                )
////            }
////        }
//        .alert("Export failed", isPresented: .constant(exportError != nil), actions: {
//            Button("OK") { exportError = nil }
//        }, message: {
//            Text(exportError ?? "")
//        })
//    }
//    
//    private func handleScanCompleted(pointCloud: SCPointCloud, meshTexturing: SCMeshTexturing?) {
//        let previewVC = ScenePreviewViewController(
//            pointCloud: pointCloud,
//            meshTexturing: meshTexturing,
//            landmarks: nil
//        )
//
//        // Extract scene + thumbnail from the preview VC
//        let scene = previewVC.scScene
//        let thumbnail = previewVC.renderedSceneImage
//        viewModel.lastScene = scene
//        viewModel.saveScene(scene: scene, thumbnail: thumbnail)
//        viewModel.showScanner = false
//        viewModel.showPreview = true
//    }
//    
//
//
//    // MARK: - Background (camera feed / 3D viewer)
//
//    @ViewBuilder
//    private var backgroundLayer: some View {
//        switch viewModel.state {
//        case .scanning:
//            CameraPreviewView(session: viewModel.cameraSession, overlay: viewModel.liveOverlay, coverage: viewModel.coverageOverlay)
//        case .reviewing:
//            SceneView(scene: viewModel.scene,
//                      options: [.allowsCameraControl, .autoenablesDefaultLighting])
//        default:
//            Color.black
//        }
//    }
//
//    // MARK: - Overlays
//
//    @ViewBuilder
//    private var topOverlay: some View {
//        switch viewModel.state {
//        case .idle:
//            VStack {
//                if let thumbnail = viewModel.lastSceneThumbnail {
//                    Button(action: {
//                        Task {
//                            try viewModel.exportOBJ()
//                        }
//                    }) {
//                        Image(uiImage: thumbnail)
//                            .resizable()
//                            .scaledToFill()
//                            .frame(width: 200, height: 200)
//                            .clipShape(RoundedRectangle(cornerRadius: 12))
//                            .overlay(
//                                RoundedRectangle(cornerRadius: 12)
//                                    .stroke(Color.white, lineWidth: 2)
//                            )
//                    }
//                } else {
//                    Text("no scan yet")
//                        .foregroundColor(.white)
//                        .frame(width: 200, height: 200)
//                        .background(Color.gray.opacity(0.3))
//                        .clipShape(RoundedRectangle(cornerRadius: 12))
//                }
//                statusPill(text: "Ready to scan", systemImage: "camera")
//            }
//        case .requestingPermission:
//            statusPill(text: "Requesting camera access…", systemImage: "lock.shield")
//        case .scanning:
//            VStack(spacing: 8) {
//                statusPill(text: "Hold still — capturing the front of your hand", systemImage: "hand.raised")
//                progressBar
//            }
//        case .reconstructing:
//            statusPill(text: "Reconstructing mesh…", systemImage: "cube.transparent")
//        case .reviewing:
//            statusPill(text: "Rotate / pinch to inspect", systemImage: "hand.draw")
//        case .error(let message):
//            statusPill(text: "Error: \(message)", systemImage: "exclamationmark.triangle", tint: .red)
//        }
//    }
//
//    /// Fills over the ~1.2s capture window — there's no coverage/rotation
//    /// target here, just a short countdown until the averaged frame is
//    /// ready to reconstruct.
//    private var progressBar: some View {
//        VStack(spacing: 4) {
//            GeometryReader { geo in
//                ZStack(alignment: .leading) {
//                    Capsule().fill(Color.white.opacity(0.25))
//                    Capsule()
//                        .fill(Color.green)
//                        .frame(width: geo.size.width * CGFloat(viewModel.captureProgress))
//                }
//            }
//            .frame(height: 8)
//            Text("\(viewModel.capturedFrameCount) frames averaged")
//                .font(.caption2)
//                .foregroundColor(.white.opacity(0.85))
//        }
//        .frame(maxWidth: 260)
//    }
//
//    private func statusPill(text: String, systemImage: String, tint: Color = .white) -> some View {
//        Label(text, systemImage: systemImage)
//            .font(.subheadline.weight(.medium))
//            .foregroundColor(tint)
//            .padding(.horizontal, 14)
//            .padding(.vertical, 8)
//            .background(.ultraThinMaterial, in: Capsule())
//    }
//
//    @ViewBuilder
//    private var bottomOverlay: some View {
//        switch viewModel.state {
//        case .idle, .error:
//            Button("Start Scan") { viewModel.startScanning() }
//                .buttonStyle(.borderedProminent)
//                .controlSize(.large)
//        case .requestingPermission, .reconstructing, .scanning:
//            ProgressView()
//                .tint(.white)
//        case .reviewing:
//            VStack(spacing: 10) {
//                HStack(spacing: 12) {
//                    Button("Export STL") { export { try viewModel.exportSTL() } }
//                    Button("Export OBJ") { export { try viewModel.exportOBJ() } }
//                    Button("Export Points") { export { try await viewModel.exportRawPointCloudPLY() } }
//                }
//                .buttonStyle(.bordered)
//
//                Button("Scan Again") { viewModel.startScanning() }
//                    .buttonStyle(.borderedProminent)
//            }
//            .padding(12)
//            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
//        }
//    }
//
//    private func export(_ action: @escaping () async throws -> URL) {
//        Task {
//            do {
//                let url = try await action()
//                presentShareSheet(for: url)
//            } catch {
//                exportError = error.localizedDescription
//            }
//        }
//    }
//
//    private func presentShareSheet(for url: URL) {
//        #if canImport(UIKit)
//        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
//        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
//           let rootVC = scene.windows.first?.rootViewController {
//            rootVC.present(activityVC, animated: true)
//        }
//        #endif
//    }
//}
//
