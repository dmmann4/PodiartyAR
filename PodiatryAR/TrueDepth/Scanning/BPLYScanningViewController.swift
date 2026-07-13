import ARKit
import CoreMotion
import MediaPlayer
import SceneKit
import StandardCyborgFusion
import UIKit

class BPLYScanningViewController: UIViewController, CameraManagerDelegate {
    
    private enum ScanningTerminationReason {
        case canceled
        case finished
    }
    
    // MARK: - Outlets and Actions
    
    @IBOutlet private weak var metalContainerView: UIView!
    @IBOutlet private weak var scanDurationContainerView: UIView!
    @IBOutlet private weak var scanDurationLabel: UILabel!
    @IBOutlet private weak var elapsedDurationLabel: UILabel!
    @IBOutlet private weak var shutterButton: UIButton!
    @IBOutlet private weak var countdownLabel: UILabel!
    
    // MARK: -
    
    @IBAction private func scanDurationChanged(_ sender: UISlider) {
        _scanDurationSeconds = Int(sender.value)
    }
    
    @IBAction private func shutterTapped(_ sender: UIButton?) {
        if _scanning {
            AudioAndHapticEngine.shared.scanningFinished()
            _stopScanning(reason: .finished)
        } else if _countdownSeconds > 0 {
            AudioAndHapticEngine.shared.scanningCanceled()
            _cancelCountdown()
        } else {
            _startCountdown { self._startScanning() }
        }
    }
    
    @IBAction func done(_ sender: UIButton) {
        _stopScanning(reason: .finished)
        
        presentingViewController?.dismiss(animated: true, completion: nil)
    }
    
    // MARK: - Properties
    
    private let _metalLayer = CAMetalLayer()
    private let _metalDevice = MTLCreateSystemDefaultDevice()!
    private lazy var _commandQueue = _metalDevice.makeCommandQueue()!
    private lazy var _reconstructionManager = SCReconstructionManager(device: _metalDevice, commandQueue: _commandQueue, maxThreadCount: 2)
    private lazy var _scanningViewRenderer = ScanningViewRenderer(device: _metalDevice, commandQueue: _commandQueue)
    private var _scanningTimer: Timer?
    private let _cameraManager = CameraManager()
    private let _motionManager = CMMotionManager()
    
    private var _useFullResolutionDepthFrames: Bool {
        get { return UserDefaults.standard.bool(forKey: "full_resolution_depth_frames", defaultValue: true) }
        set { UserDefaults.standard.set(newValue, forKey: "full_resolution_depth_frames") }
    }
    
    // MARK: - UIViewController
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        _metalLayer.isOpaque = true
        _metalLayer.contentsScale = UIScreen.main.scale
        _metalLayer.device = _metalDevice
        _metalLayer.pixelFormat = MTLPixelFormat.bgra8Unorm
        _metalLayer.framebufferOnly = false
        _metalLayer.frame = metalContainerView.bounds
        metalContainerView.layer.addSublayer(_metalLayer)
        metalContainerView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(focusOnTap)))
        
        _cameraManager.delegate = self
        _cameraManager.configureCaptureSession(maxColorResolution: 1920,
                                               maxDepthResolution: _useFullResolutionDepthFrames ? 640 : 320,
                                               maxFramerate: 30)

        
        NotificationCenter.default.addObserver(self, selector: #selector(thermalStateChanged),
                                               name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        _updateUI()
        
        _cameraManager.startSession { result in
            switch result {
            case .success:
                break
            case .configurationFailed:
                print("Configuration failed for an unknown reason")
            case .notAuthorized:
                let message = NSLocalizedString("TrueDepth Fusion doesn't have permission to use the camera, please change privacy settings",
                                                comment: "Alert message when the user has denied access to the camera")
                let alertController = UIAlertController(title: "TrueDepth Fusion", message: message, preferredStyle: .alert)
                alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
                                                        style: .cancel,
                                                        handler: nil))
                alertController.addAction(UIAlertAction(title: NSLocalizedString("Settings", comment: "Alert button to open Settings"),
                                                        style: .`default`)
                { _ in
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
                })
                
                self.present(alertController, animated: true, completion: nil)
            }
        }
        
        _motionManager.startDeviceMotionUpdates(to: OperationQueue.main) { [weak self] (motion: CMDeviceMotion?, error: Error?) in
            guard let motion = motion else { return }
            
            if self?._scanning ?? false {
                self?._bplyDepthDataAccumulator?.accumulate(deviceMotion: motion)
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        _cameraManager.stopSession()
        _motionManager.stopDeviceMotionUpdates()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        CATransaction.begin()
        CATransaction.disableActions()
        _metalLayer.frame = metalContainerView.bounds
        _metalLayer.drawableSize = CGSize( width: _metalLayer.frame.width  * _metalLayer.contentsScale,
                                          height: _metalLayer.frame.height * _metalLayer.contentsScale)
        CATransaction.commit()
    }
    
    override func didReceiveMemoryWarning() {
        _stopScanning(reason: .finished)
    }
    
    // MARK: - Notifications
    
    @objc private func focusOnTap(_ gesture: UITapGestureRecognizer) {
        guard !_scanning else { return }
        
        let location = gesture.location(in: metalContainerView)
        
        _cameraManager.focusOnTap(at: location)
    }
    
    @objc private func thermalStateChanged(notification: NSNotification) {
        guard let processInfo = notification.object as? ProcessInfo,
            processInfo.thermalState == .critical
            else { return }
        
        DispatchQueue.main.async {
            if self._scanning {
                self._stopScanning(reason: .finished)
            }
            
            let alertController = UIAlertController(title: "iPhone is too hot!",
                                                    message: "Please allow iPhone to cool down and try again",
                                                    preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))
            self.present(alertController, animated: true, completion: nil)
        }
    }
    
    // MARK: - CameraManagerDelegate
    
    func cameraDidOutput(colorBuffer: CVPixelBuffer,
                         colorTime: CMTime,
                         depthBuffer: CVPixelBuffer,
                         depthTime: CMTime,
                         depthCalibrationData: AVCameraCalibrationData)
    {
        let pointCloud = _reconstructionManager.reconstructSingleDepthBuffer(depthBuffer,
                                                                             colorBuffer: colorBuffer,
                                                                             with: depthCalibrationData,
                                                                             smoothingPoints: !self._useFullResolutionDepthFrames)
        
        _scanningViewRenderer.draw(colorBuffer: colorBuffer,
                                   depthBuffer: depthBuffer,
                                   pointCloud: pointCloud,
                                   depthCameraCalibrationData: depthCalibrationData,
                                   viewMatrix: matrix_identity_float4x4,
                                   into: _metalLayer,
                                   flipsInputHorizontally: false)
        
        if _scanning {
            _bplyDepthDataAccumulator!.accumulate(colorBuffer: colorBuffer,
                                                  colorTime: colorTime,
                                                  depthBuffer: depthBuffer,
                                                  depthTime: depthTime,
                                                  calibrationData: depthCalibrationData)
        }
    }
    
    // MARK: - UI State Management
    
    private var _bplyDepthDataAccumulator: BPLYDepthDataAccumulator?
    
    private var _scanning: Bool = false {
        didSet { _updateUI() }
    }
    
    private var _tapToStartStop: Bool {
        return UserDefaults.standard.bool(forKey: "tap_to_start_stop")
    }
    
    private var _scanDurationSeconds: Int = 5 {
        didSet { _updateUI() }
    }
    
    private var _elapsedSeconds: Int = 0 {
        didSet { _updateUI() }
    }
    
    private var _countdownSeconds: Int = 0 {
        didSet { _updateUI() }
    }
    
    private func _updateUI() {
        // Make sure the view is loaded first
        _ = self.view
        
        scanDurationContainerView.isHidden = _tapToStartStop
        elapsedDurationLabel.isHidden = !_scanning
        scanDurationLabel.text = "\(_scanDurationSeconds) sec"
        elapsedDurationLabel.text = "\(_elapsedSeconds + 1)"
        countdownLabel.isHidden = _countdownSeconds == 0
        countdownLabel.text = "\(_countdownSeconds)"
        shutterButton.setImage(UIImage(named: _scanning ? "CameraButtonRecording" : "CameraButton"), for: UIControl.State.normal)
        shutterButton.isSelected = _countdownSeconds > 0
        _cameraManager.isFocusLocked = _scanning
    }
    
    private func _startCountdown(_ completion: @escaping () -> Void) {
        _countdownSeconds = 3
        _iterateCountdown(completion)
    }
    
    private func _cancelCountdown() {
        AudioAndHapticEngine.shared.scanningCanceled()
        countdownLabel.alpha = 1
        _countdownSeconds = 0
    }
    
    private func _iterateCountdown(_ completion: @escaping () -> Void) {
        AudioAndHapticEngine.shared.countdownCountedDown()
        
        if _countdownSeconds == 0 {
            completion()
            return
        }
        
        countdownLabel.alpha = 1
        UIView.animate(withDuration: 0.7, animations: {
            self.countdownLabel.alpha = 0
        }, completion: { finished in
            if finished && self._countdownSeconds > 0 {
                self._countdownSeconds -= 1
                self._iterateCountdown(completion)
            }
        })
    }
    
    private func _startScanning() {
        AudioAndHapticEngine.shared.scanningBegan()
        _bplyDepthDataAccumulator = BPLYDepthDataAccumulator()
        
        _scanningTimer = Timer.init(timeInterval: 1, repeats: true) { [unowned self] timer in
            self._elapsedSeconds += 1
            
            if !self._tapToStartStop && self._elapsedSeconds >= self._scanDurationSeconds {
                self._stopScanning(reason: .finished)
            }
        }
        RunLoop.current.add(_scanningTimer!, forMode: RunLoop.Mode.default)
        
        _elapsedSeconds = 0
        _scanning = true
    }
    
    private func _stopScanning(reason: ScanningTerminationReason) {
        guard _scanning else { return }
        
        let accumulator = _bplyDepthDataAccumulator!
        _bplyDepthDataAccumulator = nil
        _scanning = false
        _scanningTimer?.invalidate()
        _scanningTimer = nil
        _elapsedSeconds = 0
        _updateUI()
        
        switch reason {
        case .canceled: AudioAndHapticEngine.shared.scanningCanceled()
        case .finished: AudioAndHapticEngine.shared.scanningFinished()
        }
        
        didFinishScanningSceneKitWay(rawFramesFolderURL: URL(fileURLWithPath: accumulator.containerPath()))
        
//        if reason == .finished {
//            let zipURL = accumulator.exportFrameSequenceToZip()
//            let controller = UIActivityViewController(activityItems: [zipURL], applicationActivities: nil)
//            controller.popoverPresentationController?.sourceView = elapsedDurationLabel
//            present(controller, animated: true, completion: nil)
//        }
    }
    
    func parseStandardCyborgToGeometryData(from folderURL: URL, completion: @escaping ([SCNVector3]?, Data?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            
            guard let files = try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else {
                print("❌ STAGE 1 FAIL: Cannot read directory at URL: \(folderURL)")
                completion(nil, nil)
                return
            }
            
            let plyFiles = files.filter { $0.pathExtension.lowercased() == "ply" }.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            
            guard !plyFiles.isEmpty else {
                print("❌ STAGE 2 FAIL: Found 0 .ply files.")
                completion(nil, nil)
                return
            }
            
            let headerDelimiter = "end_header\n".data(using: .utf8)!
            let width = 640
            let height = 360
            let numElements = 230400
            let colorBytes = numElements * 3 * MemoryLayout<Float>.size // 2,764,800 bytes
            let depthBytes = numElements * MemoryLayout<Float>.size     //   921,600 bytes
            
            let fx: Float = 500.0
            let fy: Float = 500.0
            let cx: Float = Float(width) / 2.0
            let cy: Float = Float(height) / 2.0
            
            var positions = [SCNVector3]()
            var colorComponents = [Float]()   // instead of Data of UInt8
            
            positions.reserveCapacity(plyFiles.count * 10000)
            colorComponents.reserveCapacity(plyFiles.count * 10000 * 4)
            
            for (fileIndex, fileURL) in plyFiles.enumerated() {
                guard let fileData = try? Data(contentsOf: fileURL),
                      let rangeOfDelimiter = fileData.range(of: headerDelimiter) else { continue }
                
                let binaryStart = rangeOfDelimiter.upperBound
                
                // --- DYNAMIC METADATA PARSING ---
                // Extract just the ASCII header bytes to parse the metadata size text safely
                let headerData = fileData.subdata(in: 0..<binaryStart)
                guard let headerString = String(data: headerData, encoding: .utf8) else {
                    print("⚠️ Warning: Could not decode header as UTF8 text for file \(fileURL.lastPathComponent)")
                    continue
                }
                
                var dynamicMetadataBytes = 570 // Fallback default
                let lines = headerString.components(separatedBy: .newlines)
                for line in lines {
                    if line.contains("element metadata") {
                        let countString = line.replacingOccurrences(of: "element metadata ", with: "").trimmingCharacters(in: .whitespaces)
                        if let parsedMetadataSize = Int(countString) {
                            dynamicMetadataBytes = parsedMetadataSize
                        }
                    }
                }
                // ---------------------------------
                
                let colorStart = binaryStart + dynamicMetadataBytes
                let depthStart = colorStart + colorBytes
                let expectedMinimumFileSize = depthStart + depthBytes
                
                // Dynamic payload boundary verification
                guard expectedMinimumFileSize <= fileData.count else {
                    print("❌ File [\(fileIndex)] Size Mismatch: Got \(fileData.count) bytes. Dynamically expected \(expectedMinimumFileSize) bytes (Metadata: \(dynamicMetadataBytes)). Skipping frame.")
                    continue
                }
                
                let colorData = fileData.subdata(in: colorStart..<depthStart)
                let depthData = fileData.subdata(in: depthStart..<expectedMinimumFileSize)
                
                colorData.withUnsafeBytes { colorBuffer in
                    depthData.withUnsafeBytes { depthBuffer in
                        guard let rColors = colorBuffer.bindMemory(to: Float.self).baseAddress,
                              let rDepths = depthBuffer.bindMemory(to: Float.self).baseAddress else { return }
                        
                        for y in 0..<height {
                            for x in 0..<width {
                                let index = y * width + x
                                let z = rDepths[index]
                                
                                if z.isNaN || z.isInfinite { continue }
                                if abs(z) < 0.01 || abs(z) > 10.0 { continue }
                                
                                let rawR = rColors[index * 3]
                                let rawG = rColors[index * 3 + 1]
                                let rawB = rColors[index * 3 + 2]
                                
                                if rawR.isNaN || rawR.isInfinite || rawG.isNaN || rawG.isInfinite || rawB.isNaN || rawB.isInfinite {
                                    continue
                                }
                                
                                let x3D = (Float(x) - cx) * z / fx
                                let y3D = (Float(y) - cy) * z / fy
                                
                                positions.append(SCNVector3(x3D, y3D, z))
                                
                                colorComponents.append(rawR)   // already 0.0–1.0 from your source data
                                colorComponents.append(rawG)
                                colorComponents.append(rawB)
                                colorComponents.append(1.0)    // alpha
                            }
                        }
                    }
                }
            }
            
            if positions.isEmpty {
                print("❌ STAGE 5 FAIL: Loop completed, but 0 valid points passed numeric filters.")
                DispatchQueue.main.async {
                    completion(nil, nil)
                }
                return
            }
            
            print("✅ SUCCESS: Dynamic compilation complete! Extracted \(positions.count) points.")
            let colorsData = Data(bytes: colorComponents, count: colorComponents.count * MemoryLayout<Float>.size)
            DispatchQueue.main.async {
                completion(positions, colorsData)
            }
        }
    }
    
    func buildPointCloudGeometry(positions: [SCNVector3], colorsData: Data) -> SCNGeometry? {
        guard !positions.isEmpty else { return nil }
        
        // 1. Build the Position Vertex Geometry Source
        let vertexSource = SCNGeometrySource(vertices: positions)
        
        // 2. Build the Color Mapping Vertex Geometry Source
        let colorSource = SCNGeometrySource(
            data: colorsData,
            semantic: .color,
            vectorCount: positions.count,
            usesFloatComponents: false, // False since we pass UInt8 (0-255)
            componentsPerVector: 4,     // RGBA components
            bytesPerComponent: MemoryLayout<UInt8>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<UInt8>.size * 4
        )
        
        // 3. Define the topology layout as tight vertex dots (Point Clouds)
        let totalPointsCount = positions.count
        let pointIndices = Array<Int32>(0..<Int32(totalPointsCount))
        let elementData = Data(bytes: pointIndices, count: pointIndices.count * MemoryLayout<Int32>.size)
        
        let element = SCNGeometryElement(
            data: elementData,
            primitiveType: .point, // <--- Key parameter: Renders as points instead of meshes
            primitiveCount: totalPointsCount,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        
        // 4. Combine into an SCNGeometry object
        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        
        // 5. Configure material to keep colors vivid
        let material = SCNMaterial()
        material.lightingModel = .constant // Bypasses light shadow processing for point clouds
        geometry.materials = [material]
        
        return geometry
    }

    // Helper mathematical boundary clamping tool
    func clamp<T: Comparable>(_ value: T, min minimum: T, max maximum: T) -> T {
        return min(max(value, minimum), maximum)
    }
    
    func didFinishScanningSceneKitWay(rawFramesFolderURL: URL) {
        // Show a loading/processing spinner to the user here...

        parseStandardCyborgToGeometryData(from: rawFramesFolderURL) { [weak self] positions, colorsData in
            guard let self = self,
                  let positions = positions,
                  let colorsData = colorsData,
                  let pointCloudGeometry = self.buildPointCloudGeometry(positions: positions, colorsData: colorsData) else {
                print("Error parsing or building point cloud geometry.")
                return
            }
            
            // Hide loading spinner...
            
            // Construct a clean, empty scene container
            let pointCloudScene = SCNScene()
            let pointCloudNode = SCNNode(geometry: pointCloudGeometry)
            pointCloudScene.rootNode.addChildNode(pointCloudNode)
            
            let viewerVC = ScanViewerViewController()
            viewerVC.pointCloudScene = pointCloudScene   // just hand it off
            self.navigationController?.pushViewController(viewerVC, animated: true)
        }
    }
    
}
