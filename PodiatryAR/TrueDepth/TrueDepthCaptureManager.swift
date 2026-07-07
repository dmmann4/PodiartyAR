import AVFoundation
import CoreImage
import simd

/// A single synchronized depth + color frame pulled from the TrueDepth camera,
/// along with the intrinsics needed to unproject depth into 3D space.
struct CapturedFrame {
    let depthMap: CVPixelBuffer
    let colorBuffer: CVPixelBuffer?
    let cameraIntrinsics: matrix_float3x3
    let timestamp: TimeInterval
}

protocol TrueDepthCaptureManagerDelegate: AnyObject {
    func captureManager(_ manager: TrueDepthCaptureManager, didCapture frame: CapturedFrame)
    func captureManager(_ manager: TrueDepthCaptureManager, didFailWithError error: Error)
}

enum CaptureError: Error {
    case deviceNotFound
    case cannotAddInput
    case cannotAddOutput
    case configurationFailed
}

/// Wraps an AVCaptureSession configured for the front TrueDepth camera,
/// delivering synchronized depth + video frames.
///
/// NOTE: TrueDepth is tuned for face-distance capture (roughly 0.15m-1.0m).
/// For a foot, keep the camera 25-40cm away and expect a smaller usable
/// volume than you'd get from the rear LiDAR scanner on Pro devices.
final class TrueDepthCaptureManager: NSObject {

    weak var delegate: TrueDepthCaptureManagerDelegate?

    /// Exposed (read-only from outside) so a UIViewRepresentable can attach
    /// an AVCaptureVideoPreviewLayer to show the live feed on screen.
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.footscan.session-queue")
    private let dataOutputQueue = DispatchQueue(label: "com.footscan.data-output-queue")

    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var depthDataOutput: AVCaptureDepthDataOutput?
    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?

    private(set) var isRunning = false

    override init() {
        super.init()
    }

    // MARK: - Public control

    func requestPermissionAndConfigure(completion: @escaping (Result<Void, Error>) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async {
                do {
                    try self.configureSession()
                    completion(.success(()))
                } catch {
                    completion(.failure(error))
                }
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                guard granted else {
                    completion(.failure(CaptureError.deviceNotFound))
                    return
                }
                self.sessionQueue.async {
                    do {
                        try self.configureSession()
                        completion(.success(()))
                    } catch {
                        completion(.failure(error))
                    }
                }
            }
        default:
            completion(.failure(CaptureError.deviceNotFound))
        }
    }

    func start() {
        sessionQueue.async {
            guard !self.session.isRunning else { return }
            self.session.startRunning()
            self.isRunning = true
        }
    }

    func stop() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            self.isRunning = false
        }
    }

    // MARK: - Session configuration

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .inputPriority

        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) else {
            throw CaptureError.deviceNotFound
        }

        // Pick the highest-resolution format that also supports depth data delivery.
        let candidateFormats = device.formats.filter { !$0.supportedDepthDataFormats.isEmpty }
        guard let bestFormat = candidateFormats.max(by: { lhs, rhs in
            let lhsDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rhsDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return (lhsDims.width * lhsDims.height) < (rhsDims.width * rhsDims.height)
        }) else {
            throw CaptureError.configurationFailed
        }

        let bestDepthFormat = bestFormat.supportedDepthDataFormats.max { lhs, rhs in
            let lhsDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rhsDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return (lhsDims.width * lhsDims.height) < (rhsDims.width * rhsDims.height)
        }

        try device.lockForConfiguration()
        device.activeFormat = bestFormat
        device.activeDepthDataFormat = bestDepthFormat
        device.unlockForConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        session.inputs.forEach { input in
            session.removeInput(input)
        }
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(videoOutput) else { throw CaptureError.cannotAddOutput }
        session.addOutput(videoOutput)
        self.videoDataOutput = videoOutput

        let depthOutput = AVCaptureDepthDataOutput()
        depthOutput.isFilteringEnabled = true
        depthOutput.alwaysDiscardsLateDepthData = true
        guard session.canAddOutput(depthOutput) else { throw CaptureError.cannotAddOutput }
        session.addOutput(depthOutput)
        self.depthDataOutput = depthOutput

        // Match video/depth connection orientation, AND force both to the
        // same (unmirrored) mirroring state. This matters beyond just visual
        // consistency: HandRegionDetector runs Vision on the color buffer
        // and hands back a normalized bounding box that FrontSurfaceCapture
        // then applies directly to the depth grid's own (gu, gv) indices.
        // That only lines up if the two buffers share the same orientation
        // AND mirroring — front camera connections mirror by default, and
        // "by default" isn't guaranteed to be the same default on both
        // connections, so this pins both to a known, identical state rather
        // than relying on it. (The live preview layer has its own separate
        // connection and mirrors independently for on-screen display —
        // see CameraPreviewView — so this doesn't affect what the user sees.)
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
        if let connection = depthOutput.connection(with: .depthData) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }

        let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
        synchronizer.setDelegate(self, queue: dataOutputQueue)
        self.outputSynchronizer = synchronizer
    }
}

// MARK: - AVCaptureDataOutputSynchronizerDelegate

extension TrueDepthCaptureManager: AVCaptureDataOutputSynchronizerDelegate {

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                 didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        guard
            let videoOutput = videoDataOutput,
            let depthOutput = depthDataOutput,
            let syncedVideoData = synchronizedDataCollection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
            let syncedDepthData = synchronizedDataCollection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData
        else { return }

        if syncedVideoData.sampleBufferWasDropped || syncedDepthData.depthDataWasDropped {
            return
        }

        let sampleBuffer = syncedVideoData.sampleBuffer
        guard let colorPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Depth values come back in meters as Float32; convert disparity if needed.
        var depthData = syncedDepthData.depthData
        if depthData.depthDataType != kCVPixelFormatType_DepthFloat32 {
            depthData = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        }

        guard let intrinsics = extractIntrinsics(from: depthData) else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let frame = CapturedFrame(depthMap: depthData.depthDataMap,
                                   colorBuffer: colorPixelBuffer,
                                   cameraIntrinsics: intrinsics,
                                   timestamp: timestamp)

        delegate?.captureManager(self, didCapture: frame)
    }

    /// Pulls intrinsics from the depth data's own calibration data (NOT the color
    /// video sample buffer). This matters because the TrueDepth video and depth
    /// streams are frequently delivered at *different* pixel resolutions (e.g.
    /// ~1920x1440 color vs ~640x480 depth) — intrinsics calibrated for the color
    /// frame do not directly apply to depth-map pixel coordinates. Using the
    /// video buffer's intrinsics against depth pixels silently produces a badly
    /// wrong focal length/optical center for every point, which is the single
    /// biggest source of garbage/warped point clouds in this pipeline.
    ///
    /// `cameraCalibrationData.intrinsicMatrix` is defined relative to
    /// `intrinsicMatrixReferenceDimensions`, so we rescale fx/fy/cx/cy to the
    /// depth map's actual pixel dimensions before handing it to the unprojector.
    private func extractIntrinsics(from depthData: AVDepthData) -> matrix_float3x3? {
        guard let calibrationData = depthData.cameraCalibrationData else { return nil }

        var intrinsics = calibrationData.intrinsicMatrix
        let referenceDimensions = calibrationData.intrinsicMatrixReferenceDimensions

        let depthWidth = Float(CVPixelBufferGetWidth(depthData.depthDataMap))
        let depthHeight = Float(CVPixelBufferGetHeight(depthData.depthDataMap))

        guard referenceDimensions.width > 0, referenceDimensions.height > 0 else { return nil }

        let scaleX = depthWidth / Float(referenceDimensions.width)
        let scaleY = depthHeight / Float(referenceDimensions.height)

        intrinsics.columns.0.x *= scaleX // fx
        intrinsics.columns.1.y *= scaleY // fy
        intrinsics.columns.2.x *= scaleX // cx
        intrinsics.columns.2.y *= scaleY // cy

        return intrinsics
    }
}
