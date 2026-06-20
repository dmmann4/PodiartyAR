import SwiftUI
import ARKit
import Combine

// MARK: - Flow state

enum ScanPhase: Equatable {
    case intro
    case unsupportedDevice
    case scanning
    case processing
    case review
    case error(String)
}

enum ScanProcessingError: LocalizedError {
    case noGeometry
    case insufficientCoverage

    var errorDescription: String? {
        switch self {
        case .noGeometry:
            return "No mesh data was captured. Try scanning again, moving the phone slowly around the foot."
        case .insufficientCoverage:
            return "Not enough of the foot was captured. Make sure to cover the arch, heel, and toes."
        }
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case usdz, obj, stl
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }
}

// MARK: - View model

@MainActor
final class FootScanFlowViewModel: ObservableObject {
    @Published var phase: ScanPhase = .intro
    @Published private(set) var processedMesh: FootMesh?
    @Published private(set) var landmarks: FootLandmarks?
    @Published private(set) var measurements: FootMeasurements?
    @Published var exportedFileURL: URL?

    let capture = FootScanCapture()

    func startScanning() {
        guard FootScanCapture.isSupported else {
            phase = .unsupportedDevice
            return
        }
        phase = .scanning
        capture.start()
    }

    func finishScanning() {
        let anchors = capture.currentMeshAnchors()
        capture.stop()
        phase = .processing

        // Plain GCD rather than Swift concurrency here on purpose: ARMeshAnchor
        // doesn't conform to Sendable, so handing it across a Task boundary trips
        // strict concurrency checking. A manual background queue sidesteps that
        // for this example — if you migrate to async/await, copy the raw vertex
        // data out of the anchors on the main thread first.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let result = try Self.processScan(anchors: anchors)
                DispatchQueue.main.async {
                    self.processedMesh = result.mesh
                    self.landmarks = result.landmarks
                    self.measurements = result.measurements
                    self.phase = .review
                }
            } catch {
                DispatchQueue.main.async {
                    self.phase = .error(error.localizedDescription)
                }
            }
        }
    }

    func export(format: ExportFormat) {
        guard let mesh = processedMesh else { return }
        let filename = "foot-scan-\(Int(Date().timeIntervalSince1970))"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)
            .appendingPathExtension(format.fileExtension)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                switch format {
                case .usdz: try MeshExporter.exportUSDZ(mesh, to: url)
                case .obj: try MeshExporter.exportOBJ(mesh, to: url)
                case .stl: try MeshExporter.exportSTL(mesh, to: url)
                }
                DispatchQueue.main.async { self?.exportedFileURL = url }
            } catch {
                DispatchQueue.main.async {
                    self?.phase = .error("Export failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func reset() {
        processedMesh = nil
        landmarks = nil
        measurements = nil
        exportedFileURL = nil
        phase = .intro
    }

    // MARK: - Processing pipeline

    nonisolated private static func processScan(
        anchors: [ARMeshAnchor]
    ) throws -> (mesh: FootMesh, landmarks: FootLandmarks, measurements: FootMeasurements) {
        guard !anchors.isEmpty else { throw ScanProcessingError.noGeometry }

        let fused = FootMeshProcessor.fuse(anchors)
        let floorY = estimateFloorY(fused.vertices)
        let isolated = FootMeshProcessor.isolateFoot(fused, floorY: floorY)

        guard isolated.vertices.count > 200 else { throw ScanProcessingError.insufficientCoverage }

        let smoothed = FootMeshProcessor.smooth(isolated)
        let decimated = FootMeshProcessor.decimate(smoothed)

        let landmarks = FootLandmarkPredictor.predict(mesh: decimated)
        let measurements = FootMeshProcessor.boundingMeasurements(decimated)

        return (decimated, landmarks, measurements)
    }

    /// No explicit plane tracking here — approximated as a low percentile of
    /// captured vertex heights. Works as long as some floor geometry got captured
    /// around the foot; swap in ARPlaneAnchor tracking for uneven or cluttered floors.
    nonisolated private static func estimateFloorY(_ vertices: [SIMD3<Float>]) -> Float {
        guard !vertices.isEmpty else { return 0 }
        let sorted = vertices.map(\.y).sorted()
        let index = max(0, Int(Double(sorted.count) * 0.02))
        return sorted[index]
    }
}

// MARK: - Top-level flow

struct FootScanFlowView: View {
    @StateObject private var viewModel = FootScanFlowViewModel()

    var body: some View {
        Group {
            switch viewModel.phase {
            case .intro:
                IntroView(onStart: viewModel.startScanning)
            case .unsupportedDevice:
                UnsupportedDeviceView(onDismiss: viewModel.reset)
            case .scanning:
                ScanningView(capture: viewModel.capture, onFinish: viewModel.finishScanning)
            case .processing:
                ProcessingView()
            case .review:
                if let mesh = viewModel.processedMesh,
                   let landmarks = viewModel.landmarks,
                   let measurements = viewModel.measurements {
                    ReviewView(mesh: mesh, landmarks: landmarks, measurements: measurements, viewModel: viewModel)
                } else {
                    ErrorView(message: "Something went wrong processing the scan.", onRetry: viewModel.reset)
                }
            case .error(let message):
                ErrorView(message: message, onRetry: viewModel.reset)
            }
        }
        .animation(.default, value: viewModel.phase)
    }
}

// MARK: - Phase screens

private struct IntroView: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "shoeprints.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Foot scan")
                .font(.title2.bold())
            Text("Place your foot on a flat, well-lit surface, then slowly circle the phone around it — including the arch and heel.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(action: onStart) {
                Text("Start scanning")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 32)
        }
    }
}

private struct UnsupportedDeviceView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("LiDAR required")
                .font(.title2.bold())
            Text("This device doesn't have a LiDAR scanner. Foot scanning requires an iPhone 12 Pro or later Pro model, or a 2020+ iPad Pro.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("OK", action: onDismiss)
        }
    }
}

private struct ProcessingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Processing scan…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.octagon")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try again", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct ReviewView: View {
    let mesh: FootMesh
    let landmarks: FootLandmarks
    let measurements: FootMeasurements
    @ObservedObject var viewModel: FootScanFlowViewModel
    @State private var isExporting = false

    var body: some View {
        NavigationStack {
            InteractiveFootView(mesh: mesh, landmarks: landmarks, measurements: measurements)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Scan again", action: viewModel.reset)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            ForEach(ExportFormat.allCases) { format in
                                Button(format.label) {
                                    viewModel.export(format: format)
                                    isExporting = true
                                }
                            }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .sheet(isPresented: $isExporting, onDismiss: { viewModel.exportedFileURL = nil }) {
                    if let url = viewModel.exportedFileURL {
                        ShareSheet(activityItems: [url])
                    } else {
                        ProgressView("Preparing file…")
                    }
                }
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
