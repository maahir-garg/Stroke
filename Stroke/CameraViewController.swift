import UIKit
import AVFoundation
import Vision

// Make finger types file-scoped so extensions and helper functions can reference them easily.
fileprivate struct FingerPoint: Codable {
    let x: Double
    let y: Double
    let t: Double
}

fileprivate class TrackedFinger {
    let id: Int
    var lastPoint: CGPoint?
    var points: [FingerPoint] = []
    init(id: Int) { self.id = id }
}

class CameraViewController: UIViewController {

    fileprivate var cameraView: CameraView { view as! CameraView }

    private let videoDataOutputQueue = DispatchQueue(label: "CameraFeedDataOutput", qos: .userInteractive)
    private var cameraFeedSession: AVCaptureSession?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var currentCameraPosition: AVCaptureDevice.Position = .back
    private var handPoseRequest = VNDetectHumanHandPoseRequest()

    // Drawing overlay (kept for visualizing points)
    private let drawOverlay = CAShapeLayer()
    private let drawPath = UIBezierPath()

    // old gesture/drawing state - kept for backward compatibility (not used for index-only tracking)
    private var evidenceBuffer = [HandGestureProcessor.PointsPair]()
    private var lastDrawPoint: CGPoint?
    private var isFirstSegment = true
    private var lastObservationTimestamp = Date()

    // Tracking state
    fileprivate var isTracking = false

    fileprivate var trackedFingers: [TrackedFinger] = []
    fileprivate var nextFingerID = 1
    fileprivate let matchDistanceThreshold: CGFloat = 60.0 // points in view coords

    private var gestureProcessor = HandGestureProcessor()

    // UI controls
    private var switchCameraButton: UIButton!
    private var startButton: UIButton!
    private var stopButton: UIButton!
    private var trackingStatusLabel: UILabel!

    // Per-finger trail layers
    private var fingerTrailLayers: [Int: CAShapeLayer] = [:]
    
    override func viewDidLoad() {
        super.viewDidLoad()
    drawOverlay.frame = view.layer.bounds
    drawOverlay.lineWidth = 5
    // Make overlay transparent — user requested no pale white overlay
    drawOverlay.backgroundColor = UIColor.clear.cgColor
        drawOverlay.strokeColor = #colorLiteral(red: 0.6, green: 0.1, blue: 0.3, alpha: 1).cgColor
        drawOverlay.fillColor = #colorLiteral(red: 0.9999018312, green: 1, blue: 0.9998798966, alpha: 0).cgColor
        drawOverlay.lineCap = .round
        view.layer.addSublayer(drawOverlay)
    // Allow detecting multiple hands (index fingers) — set to a reasonable max.
    handPoseRequest.maximumHandCount = 4
        // Add state change handler to hand gesture processor.
        gestureProcessor.didChangeStateClosure = { [weak self] state in
            self?.handleGestureStateChange(state: state)
        }
        // Add double tap gesture recognizer for clearing the draw path.
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        recognizer.numberOfTouchesRequired = 1
        recognizer.numberOfTapsRequired = 2
        view.addGestureRecognizer(recognizer)
        // Add UI controls for camera switch and tracking
        setupControls()

        // Observe orientation changes to update preview and capture connection
        NotificationCenter.default.addObserver(self, selector: #selector(deviceOrientationDidChange), name: UIDevice.orientationDidChangeNotification, object: nil)
        // Add rotate hint label (hidden by default)
        setupRotateHint()
        // Apply initial device-specific rules (hide flip on iPhone, etc.)
        applyDeviceOrientationRestrictions()
    }

    private var rotateHintLabel: UILabel!

    private func setupRotateHint() {
        rotateHintLabel = UILabel()
        rotateHintLabel.translatesAutoresizingMaskIntoConstraints = false
        rotateHintLabel.text = "Rotate device to landscape"
        rotateHintLabel.textColor = .white
        rotateHintLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        rotateHintLabel.textAlignment = .center
        rotateHintLabel.layer.cornerRadius = 8
        rotateHintLabel.layer.masksToBounds = true
        rotateHintLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        rotateHintLabel.isHidden = true
        view.addSubview(rotateHintLabel)
        NSLayoutConstraint.activate([
            rotateHintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            rotateHintLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            rotateHintLabel.widthAnchor.constraint(equalToConstant: 260),
            rotateHintLabel.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func applyDeviceOrientationRestrictions() {
        // If running on iPhone, restrict to back camera only and hide flip control.
        if UIDevice.current.userInterfaceIdiom == .phone {
            // force back camera
            currentCameraPosition = .back
            switchCameraButton.isHidden = true
        } else {
            // iPad: allow flip
            switchCameraButton.isHidden = false
        }
        // Immediately enforce allowed orientation/camera
        updateAllowedStateForInterfaceOrientation()
    }

    private func updateAllowedStateForInterfaceOrientation() {
        // Determine allowed orientations per device
        let idiom = UIDevice.current.userInterfaceIdiom
        var allowed = false
        if let scene = view.window?.windowScene {
            let io = scene.interfaceOrientation
            if idiom == .phone {
                allowed = io.isLandscape
                // ensure back camera only
                currentCameraPosition = .back
            } else {
                // iPad: require landscape
                allowed = io.isLandscape
            }
        } else {
            // Fallback when windowScene is not yet available (e.g. during early view lifecycle).
            // Use device orientation as a best-effort fallback.
            let devOri = UIDevice.current.orientation
            if idiom == .phone {
                allowed = devOri.isLandscape
                currentCameraPosition = .back
            } else {
                allowed = devOri.isLandscape
            }
        }

        if !allowed {
            // Show rotate hint and stop camera
            rotateHintLabel.isHidden = false
            trackingStatusLabel.isHidden = true
            cameraFeedSession?.stopRunning()
            // disable controls
            startButton.isEnabled = false
            stopButton.isEnabled = false
        } else {
            rotateHintLabel.isHidden = true
            trackingStatusLabel.isHidden = false
            startButton.isEnabled = true
            // ensure camera position matches policy
            if UIDevice.current.userInterfaceIdiom == .phone {
                ensureCameraPosition(.back)
            }
            // start running if needed
            if cameraFeedSession != nil && !(cameraFeedSession?.isRunning ?? false) {
                cameraFeedSession?.startRunning()
            }
        }
    }

    private func ensureCameraPosition(_ position: AVCaptureDevice.Position) {
        guard currentCameraPosition != position else { return }
        currentCameraPosition = position
        // If session exists, switch camera
        if cameraFeedSession != nil {
            switchCamera()
        }
    }

    @objc private func deviceOrientationDidChange() {
        // Update preview and capture orientation when device/interface orientation changes
        updateOrientation()
    }

    private func updateOrientation() {
        guard let orientation = currentVideoOrientation() else { return }
        if let previewConnection = cameraView.previewLayer.connection {
            previewConnection.videoOrientation = orientation
        }
        if let dataConn = videoDataOutput?.connection(with: .video) {
            dataConn.videoOrientation = orientation
        }
    }

    private func currentVideoOrientation() -> AVCaptureVideoOrientation? {
        // Prefer interface orientation (correct for rotated UI), fall back to device orientation
        if let scene = view.window?.windowScene {
            let interface = scene.interfaceOrientation
            switch interface {
            case .portrait: return .portrait
            case .portraitUpsideDown: return .portraitUpsideDown
            case .landscapeLeft: return .landscapeLeft
            case .landscapeRight: return .landscapeRight
            default: break
            }
        }
        return AVCaptureVideoOrientation(deviceOrientation: UIDevice.current.orientation)
    }

    private func setupControls() {
        // Switch camera button
        switchCameraButton = UIButton(type: .system)
        switchCameraButton.setTitle("Flip", for: .normal)
        switchCameraButton.addTarget(self, action: #selector(switchCameraTapped), for: .touchUpInside)
        switchCameraButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(switchCameraButton)

        // Start tracking button
        startButton = UIButton(type: .system)
        startButton.setTitle("Start", for: .normal)
        startButton.addTarget(self, action: #selector(startTrackingTapped), for: .touchUpInside)
        startButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(startButton)

        // Stop tracking button
        stopButton = UIButton(type: .system)
        stopButton.setTitle("Stop", for: .normal)
        stopButton.addTarget(self, action: #selector(stopTrackingTapped), for: .touchUpInside)
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stopButton)

        // Layout
        NSLayoutConstraint.activate([
            switchCameraButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            switchCameraButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),

            startButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            startButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            stopButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stopButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])

        // Tracking status label
        trackingStatusLabel = UILabel()
        trackingStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        trackingStatusLabel.text = "Tracking: OFF"
        trackingStatusLabel.textColor = .white
        trackingStatusLabel.backgroundColor = UIColor.systemRed.withAlphaComponent(0.8)
        trackingStatusLabel.textAlignment = .center
        trackingStatusLabel.layer.cornerRadius = 6
        trackingStatusLabel.layer.masksToBounds = true
        trackingStatusLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        view.addSubview(trackingStatusLabel)

        NSLayoutConstraint.activate([
            trackingStatusLabel.topAnchor.constraint(equalTo: startButton.bottomAnchor, constant: 8),
            trackingStatusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            trackingStatusLabel.widthAnchor.constraint(equalToConstant: 140),
            trackingStatusLabel.heightAnchor.constraint(equalToConstant: 28),
        ])

        // Initial button state
        stopButton.isEnabled = false
    }

    @objc private func switchCameraTapped() {
        switchCamera()
    }

    @objc private func startTrackingTapped() {
        // Reset existing tracking
        // clear any existing trails
        trackedFingers.removeAll()
        nextFingerID = 1
        for layer in fingerTrailLayers.values { layer.removeFromSuperlayer() }
        fingerTrailLayers.removeAll()
        isTracking = true
        // UI updates
        trackingStatusLabel.text = "Tracking: ON"
        trackingStatusLabel.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.8)
        startButton.isEnabled = false
        stopButton.isEnabled = true
    }

    @objc private func stopTrackingTapped() {
        isTracking = false
        // UI updates
        trackingStatusLabel.text = "Tracking: OFF"
        trackingStatusLabel.backgroundColor = UIColor.systemRed.withAlphaComponent(0.8)
        startButton.isEnabled = true
        stopButton.isEnabled = false
        exportTrackedFingersJSON()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        do {
            if cameraFeedSession == nil {
                cameraView.previewLayer.videoGravity = .resizeAspectFill
                try setupAVSession()
                cameraView.previewLayer.session = cameraFeedSession
            }
            cameraFeedSession?.startRunning()
            // Re-evaluate allowed orientation now that the view is in the window/scene.
            updateAllowedStateForInterfaceOrientation()
        } catch {
            AppError.display(error, inViewController: self)
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        cameraFeedSession?.stopRunning()
        super.viewWillDisappear(animated)
    }
    
    func setupAVSession() throws {
        // Select camera based on currentCameraPosition
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentCameraPosition) else {
            throw AppError.captureSessionSetup(reason: "Could not find camera for requested position.")
        }

        guard let deviceInput = try? AVCaptureDeviceInput(device: videoDevice) else {
            throw AppError.captureSessionSetup(reason: "Could not create video device input.")
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = AVCaptureSession.Preset.high

        // Add a video input.
        guard session.canAddInput(deviceInput) else {
            throw AppError.captureSessionSetup(reason: "Could not add video device input to the session")
        }
        session.addInput(deviceInput)

    let dataOutput = AVCaptureVideoDataOutput()
    // keep strong reference so we can update its connection orientation later
    self.videoDataOutput = dataOutput
        if session.canAddOutput(dataOutput) {
            session.addOutput(dataOutput)
            // Add a video data output.
            dataOutput.alwaysDiscardsLateVideoFrames = true
            dataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]
            dataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
            // Match connection orientation to current interface orientation
            if let connection = dataOutput.connection(with: .video) {
                if let orientation = currentVideoOrientation() {
                    connection.videoOrientation = orientation
                }
            }
        } else {
            throw AppError.captureSessionSetup(reason: "Could not add video data output to the session")
        }
        session.commitConfiguration()
        cameraFeedSession = session

        // Ensure preview layer orientation
        if let previewConnection = cameraView.previewLayer.connection, let orientation = currentVideoOrientation() {
            previewConnection.videoOrientation = orientation
        }
    }

    private func switchCamera() {
        guard let session = cameraFeedSession else { return }
        session.beginConfiguration()
        guard let currentInput = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first else {
            session.commitConfiguration()
            return
        }
        session.removeInput(currentInput)
        // Toggle
        let newPosition: AVCaptureDevice.Position = (currentCameraPosition == .back) ? .front : .back
        currentCameraPosition = newPosition
        if let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition), let newInput = try? AVCaptureDeviceInput(device: newDevice), session.canAddInput(newInput) {
            session.addInput(newInput)
        } else {
            // Re-add previous input if new one can't be added
            if session.canAddInput(currentInput) {
                session.addInput(currentInput)
            }
        }
        session.commitConfiguration()
        // update orientation on new input/connection
        updateOrientation()
    }
    
    func processPoints(thumbTip: CGPoint?, indexTip: CGPoint?) {
        // Check that we have both points.
        guard let thumbPoint = thumbTip, let indexPoint = indexTip else {
            // If there were no observations for more than 2 seconds reset gesture processor.
            if Date().timeIntervalSince(lastObservationTimestamp) > 2 {
                gestureProcessor.reset()
            }
            cameraView.showPoints([], color: .clear)
            return
        }
        
        // Convert points from AVFoundation coordinates to UIKit coordinates.
        let previewLayer = cameraView.previewLayer
        let thumbPointConverted = previewLayer.layerPointConverted(fromCaptureDevicePoint: thumbPoint)
        let indexPointConverted = previewLayer.layerPointConverted(fromCaptureDevicePoint: indexPoint)
        
        // Process new points
        gestureProcessor.processPointsPair((thumbPointConverted, indexPointConverted))
    }
    
    private func handleGestureStateChange(state: HandGestureProcessor.State) {
        let pointsPair = gestureProcessor.lastProcessedPointsPair
        var tipsColor: UIColor
        switch state {
        case .possiblePinch, .possibleApart:
            // We are in one of the "possible": states, meaning there is not enough evidence yet to determine
            // if we want to draw or not. For now, collect points in the evidence buffer, so we can add them
            // to a drawing path when required.
            evidenceBuffer.append(pointsPair)
            tipsColor = .orange
        case .pinched:
            // We have enough evidence to draw. Draw the points collected in the evidence buffer, if any.
            for bufferedPoints in evidenceBuffer {
                updatePath(with: bufferedPoints, isLastPointsPair: false)
            }
            // Clear the evidence buffer.
            evidenceBuffer.removeAll()
            // Finally, draw the current point.
            updatePath(with: pointsPair, isLastPointsPair: false)
            tipsColor = .green
        case .apart, .unknown:
            // We have enough evidence to not draw. Discard any evidence buffer points.
            evidenceBuffer.removeAll()
            // And draw the last segment of our draw path.
            updatePath(with: pointsPair, isLastPointsPair: true)
            tipsColor = .red
        }
        cameraView.showPoints([pointsPair.thumbTip, pointsPair.indexTip], color: tipsColor)
    }
    
    private func updatePath(with points: HandGestureProcessor.PointsPair, isLastPointsPair: Bool) {
        // Get the mid point between the tips.
        let (thumbTip, indexTip) = points
        let drawPoint = CGPoint.midPoint(p1: thumbTip, p2: indexTip)

        if isLastPointsPair {
            if let lastPoint = lastDrawPoint {
                // Add a straight line from the last midpoint to the end of the stroke.
                drawPath.addLine(to: lastPoint)
            }
            // We are done drawing, so reset the last draw point.
            lastDrawPoint = nil
        } else {
            if lastDrawPoint == nil {
                // This is the beginning of the stroke.
                drawPath.move(to: drawPoint)
                isFirstSegment = true
            } else {
                let lastPoint = lastDrawPoint!
                // Get the midpoint between the last draw point and the new point.
                let midPoint = CGPoint.midPoint(p1: lastPoint, p2: drawPoint)
                if isFirstSegment {
                    // If it's the first segment of the stroke, draw a line to the midpoint.
                    drawPath.addLine(to: midPoint)
                    isFirstSegment = false
                } else {
                    // Otherwise, draw a curve to a midpoint using the last draw point as a control point.
                    drawPath.addQuadCurve(to: midPoint, controlPoint: lastPoint)
                }
            }
            // Remember the last draw point for the next update pass.
            lastDrawPoint = drawPoint
        }
        // Update the path on the overlay layer.
        drawOverlay.path = drawPath.cgPath
    }
    
    @IBAction func handleGesture(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else {
            return
        }
        evidenceBuffer.removeAll()
        drawPath.removeAllPoints()
        drawOverlay.path = drawPath.cgPath
    }
}

// MARK: - Tracking helpers & JSON export
extension CameraViewController {
    fileprivate func processDetectedIndexTips(viewPoints: [CGPoint], normalizedPoints: [CGPoint]) {
        guard viewPoints.count == normalizedPoints.count else { return }
        let timestamp = Date().timeIntervalSince1970

        // If not tracking, just visualize points and return
        if !isTracking {
            cameraView.showPoints(viewPoints, color: .green)
            return
        }

        // Match detected points to existing tracked fingers
        var assigned = [Bool](repeating: false, count: viewPoints.count)

        // Try to match each existing tracked finger to nearest detection
        for tracked in trackedFingers {
            var bestIndex: Int? = nil
            var bestDistance: CGFloat = .greatestFiniteMagnitude
            if let last = tracked.lastPoint {
                for (i, vp) in viewPoints.enumerated() where !assigned[i] {
                    let d = last.distance(from: vp)
                    if d < bestDistance {
                        bestDistance = d
                        bestIndex = i
                    }
                }
            }
            if let match = bestIndex, bestDistance <= matchDistanceThreshold {
                // assign
                assigned[match] = true
                tracked.lastPoint = viewPoints[match]
                let np = normalizedPoints[match]
                tracked.points.append(FingerPoint(x: Double(np.x), y: Double(np.y), t: timestamp))
            } else {
                // No match found this frame; we keep tracked finger but do not append
                tracked.lastPoint = nil
            }
        }

        // Any unassigned detection becomes a new tracked finger
        for (i, assignedFlag) in assigned.enumerated() where !assignedFlag {
            let tf = TrackedFinger(id: nextFingerID)
            nextFingerID += 1
            tf.lastPoint = viewPoints[i]
            let np = normalizedPoints[i]
            tf.points.append(FingerPoint(x: Double(np.x), y: Double(np.y), t: timestamp))
            trackedFingers.append(tf)
        }

        // Visualize all current detected points
        cameraView.showPoints(viewPoints, color: .green)

        // Update trail layers for tracked fingers
        updateFingerTrails()
    }

    private func updateFingerTrails() {
        let preview = cameraView.previewLayer
        for tf in trackedFingers {
            // convert stored normalized points to layer points
            var layerPoints: [CGPoint] = []
            for p in tf.points {
                // p.x/p.y are in capture device normalized coords (y already flipped when stored)
                let capPoint = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
                let lp = preview.layerPointConverted(fromCaptureDevicePoint: capPoint)
                layerPoints.append(lp)
            }
            if layerPoints.isEmpty { continue }
            let path = UIBezierPath()
            path.move(to: layerPoints[0])
            for pt in layerPoints.dropFirst() { path.addLine(to: pt) }

            let layer: CAShapeLayer
            if let existing = fingerTrailLayers[tf.id] {
                layer = existing
            } else {
                layer = CAShapeLayer()
                layer.fillColor = UIColor.clear.cgColor
                layer.lineWidth = 3
                layer.lineCap = .round
                layer.strokeColor = colorForFinger(id: tf.id).cgColor
                cameraView.previewLayer.addSublayer(layer)
                fingerTrailLayers[tf.id] = layer
            }
            layer.path = path.cgPath
        }
        // Remove layers for fingers that are no longer tracked
        let activeIDs = Set(trackedFingers.map { $0.id })
        for (id, layer) in fingerTrailLayers where !activeIDs.contains(id) {
            layer.removeFromSuperlayer()
            fingerTrailLayers.removeValue(forKey: id)
        }
    }

    private func colorForFinger(id: Int) -> UIColor {
        // deterministic hue per id
        let hue = CGFloat((id * 37) % 360) / 360.0
        return UIColor(hue: hue, saturation: 0.9, brightness: 0.9, alpha: 1)
    }

    fileprivate func exportTrackedFingersJSON() {
        // Build JSON structure
        struct ExportedFinger: Codable {
            let id: Int
            let color: String
            let points: [FingerPoint]
        }
        struct ExportPayload: Codable {
            let createdAt: Double
            let fingers: [ExportedFinger]
        }

        let exported = trackedFingers.map { tf -> ExportedFinger in
            return ExportedFinger(id: tf.id, color: colorForFinger(id: tf.id).toHexString(), points: tf.points)
        }
        let payload = ExportPayload(createdAt: Date().timeIntervalSince1970, fingers: exported)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        do {
            let data = try encoder.encode(payload)
            // Write JSON to temporary file
            let jsonURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tracked_index_fingers_\(Int(Date().timeIntervalSince1970)).json")
            try data.write(to: jsonURL)

            // Create snapshot image of the preview + overlays so user can see the visual overlay
            var snapshotURL: URL? = nil
            if let image = snapshotPreview() {
                let imageData = image.pngData()
                if let imageData = imageData {
                    let imgURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tracked_overlay_\(Int(Date().timeIntervalSince1970)).png")
                    try imageData.write(to: imgURL)
                    snapshotURL = imgURL
                }
            }

            // Present share sheet with JSON and optional image
            var items: [Any] = [jsonURL]
            if let s = snapshotURL { items.append(s) }
            let av = UIActivityViewController(activityItems: items, applicationActivities: nil)
            if let pop = av.popoverPresentationController {
                pop.sourceView = stopButton ?? self.view
            }
            present(av, animated: true, completion: nil)
        } catch {
            let appError = AppError.captureSessionSetup(reason: "Failed to create JSON/export: \(error)")
            appError.displayInViewController(self)
        }
    }

    private func snapshotPreview() -> UIImage? {
        // Snapshot the cameraView (preview layer + overlays). Use drawHierarchy for best result.
        UIGraphicsBeginImageContextWithOptions(cameraView.bounds.size, false, UIScreen.main.scale)
        defer { UIGraphicsEndImageContext() }
        let success = cameraView.drawHierarchy(in: cameraView.bounds, afterScreenUpdates: false)
        if success, let image = UIGraphicsGetImageFromCurrentImageContext() {
            return image
        }
        // fallback: render layer directly
        let renderer = UIGraphicsImageRenderer(size: cameraView.bounds.size)
        return renderer.image { ctx in
            cameraView.layer.render(in: ctx.cgContext)
        }
    }

}

// MARK: - UIColor hex helper
private extension UIColor {
    func toHexString() -> String {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = Int(round(r * 255))
        let gi = Int(round(g * 255))
        let bi = Int(round(b * 255))
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }
}

// Convert UIDeviceOrientation to AVCaptureVideoOrientation helper
private extension AVCaptureVideoOrientation {
    init?(deviceOrientation: UIDeviceOrientation) {
        switch deviceOrientation {
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeRight // device vs capture orientation differ
        case .landscapeRight: self = .landscapeLeft
        default: return nil
        }
    }
}

extension CameraViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([handPoseRequest])
            guard let observations = handPoseRequest.results, observations.count > 0 else { return }
            var normalizedPoints: [CGPoint] = []
            var viewPoints: [CGPoint] = []
            // Use a high confidence threshold for index tip as requested.
            let confidenceThreshold: VNConfidence = 0.85
            for observation in observations {
                let indexPoints = try observation.recognizedPoints(.indexFinger)
                if let indexTipPoint = indexPoints[.indexTip], indexTipPoint.confidence >= confidenceThreshold {
                    // Convert Vision normalized point to capture device coordinates (flip Y) then to view coordinates on main thread
                    let normalized = CGPoint(x: indexTipPoint.location.x, y: 1 - indexTipPoint.location.y)
                    normalizedPoints.append(normalized)
                    // Convert to view coordinates on main thread later
                }
            }
            if normalizedPoints.isEmpty { return }
            // Convert normalized capture-device points to view layer points on main thread and process
            DispatchQueue.main.async {
                let preview = self.cameraView.previewLayer
                for p in normalizedPoints {
                    let lp = preview.layerPointConverted(fromCaptureDevicePoint: p)
                    viewPoints.append(lp)
                }
                self.processDetectedIndexTips(viewPoints: viewPoints, normalizedPoints: normalizedPoints)
            }
        } catch {
            cameraFeedSession?.stopRunning()
            let error = AppError.visionError(error: error)
            DispatchQueue.main.async {
                error.displayInViewController(self)
            }
        }
    }
}

