@preconcurrency import AVFoundation
import Combine
import CoreLocation
import CoreVideo
import Darwin
import ImageIO
import SwiftUI
import UIKit

// Only request identity crosses actors. Never hold this lock during camera work.
nonisolated private final class CameraSessionRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var currentID: UUID?

    func replace(with id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        currentID = id
    }

    func isCurrent(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentID == id
    }
}

@MainActor
final class CameraService: NSObject, ObservableObject {
    enum Mode: Hashable {
        case photo
        case video
    }

    let session = AVCaptureSession()
    @Published var mode: Mode = .photo {
        didSet {
            updateCapturePreset()
            updateLocationTracking()
            resetAutoMacroDecision(cooldown: 2)
        }
    }
    @Published private(set) var isAuthorized = false
    @Published private(set) var isCameraAccessDenied = false
    @Published private(set) var isReady = false
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .back
    @Published private(set) var previewDevice: AVCaptureDevice?
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var flashMode: AVCaptureDevice.FlashMode = .off
    @Published private(set) var videoTorchMode: AVCaptureDevice.TorchMode = .off
    @Published private(set) var videoExposureBias: Float = 0
    @Published private(set) var photoExposureBias: Float = 0
    @Published private(set) var isMacroEnabled = false
    @Published private(set) var isAutoMacroEnabled = true
    @Published var errorMessage: String?

    var recordingElapsedSeconds: Int {
        guard isRecording, hasRecordingStarted else { return 0 }
        let seconds = CMTimeGetSeconds(movieOutput.recordedDuration)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(seconds.rounded(.down))
    }

    var hasFlash: Bool { videoInput?.device.hasFlash == true }
    var supportedVideoTorchModes: [AVCaptureDevice.TorchMode] {
        guard let device = videoInput?.device, device.hasTorch else { return [] }
        let modes: [AVCaptureDevice.TorchMode] = [.auto, .on, .off]
        return modes.filter {
            device.isTorchModeSupported($0) && ($0 == .off || device.isTorchAvailable)
        }
    }
    var videoTorchDescription: String {
        guard !supportedVideoTorchModes.isEmpty else { return "Unavailable" }
        switch videoTorchMode {
        case .auto: return "Auto"
        case .on: return "On"
        case .off: return "Off"
        @unknown default: return "Off"
        }
    }
    var exposureBias: Float { mode == .photo ? photoExposureBias : videoExposureBias }
    private func storeExposureBias(_ value: Float) {
        if mode == .photo { photoExposureBias = value }
        else { videoExposureBias = value }
    }
    var exposureRange: ClosedRange<Float> {
        guard let device = videoInput?.device else { return 0...0 }
        let lower = min(max(-2, device.minExposureTargetBias), device.maxExposureTargetBias)
        let upper = min(max(2, device.minExposureTargetBias), device.maxExposureTargetBias)
        return lower...upper
    }
    var canAdjustExposure: Bool {
        guard let device = videoInput?.device else { return false }
        return device.isExposureModeSupported(.continuousAutoExposure) &&
            exposureRange.lowerBound < exposureRange.upperBound
    }
    var canSuppressShutterSound: Bool { isReady && photoOutput.isShutterSoundSuppressionSupported }
    var supportedFlashModes: [AVCaptureDevice.FlashMode] {
        [.auto, .on, .off].filter { mode in
            photoOutput.supportedFlashModes.contains(mode)
        }
    }
    var isMacroAvailable: Bool { cameraPosition == .back && macroCamera != nil }
    var availableZoomFactors: [CGFloat] {
        guard videoInput != nil else { return [1] }
        guard cameraPosition == .back else { return [1] }
        let lensFactors = physicalBackLenses.map { $0.baseZoom }
        var factors = lensFactors + [1, 2]
        // Offer an 8× crop shortcut when a 4× telephoto is present.
        if lensFactors.contains(where: { abs($0 - 4) < 0.1 }) {
            factors.append(8)
        }
        if ultraWideCamera != nil { factors.append(0.5) }
        return factors.filter { factor in
            guard let lens = physicalBackLens(for: factor) else { return false }
            let deviceFactor = factor / lens.baseZoom
            return deviceFactor >= lens.device.minAvailableVideoZoomFactor &&
                deviceFactor <= lens.device.maxAvailableVideoZoomFactor
        }
        .map { (round($0 * 10) / 10) }
        .reduce(into: [CGFloat]()) { result, factor in
            if !result.contains(factor) { result.append(factor) }
        }
        .sorted()
    }
    var flashSymbol: String {
        switch flashMode {
        case .off: "bolt.slash.fill"
        case .auto: "bolt.fill"
        case .on: "bolt.fill"
        @unknown default: "bolt.slash.fill"
        }
    }
    var flashDescription: String {
        switch flashMode {
        case .off: "Off"
        case .auto: "Auto"
        case .on: "On"
        @unknown default: "Off"
        }
    }

    var onPhoto: ((Data) -> Void)?
    var onVideo: ((URL, VideoCaptureDetails?) -> Void)?

    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var configuredVideoFormat: AVCaptureDevice.Format?
    private var configuredVideoDeviceID: String?
    private var configuredVideoColorSpace: AVCaptureColorSpace?
    private var configuredVideoCodec: AVVideoCodecType?
    private let sessionQueue = DispatchQueue(label: "WorkCamera.captureSession")
    private let ultraWideCamera: AVCaptureDevice? = {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera], mediaType: .video, position: .back
        )
        return discovery.devices.first
    }()
    private var macroCamera: AVCaptureDevice? {
        guard let camera = ultraWideCamera,
              !camera.isVirtualDevice,
              camera.minimumFocusDistance > 0,
              camera.minimumFocusDistance <= 100,
              camera.isFocusModeSupported(.continuousAutoFocus) else { return nil }
        return camera
    }
    private var wideBackCamera: AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }
    // Read lens/zoom metadata only; never use this virtual device as a session input.
    private var backCameraLensMetadata: AVCaptureDevice? {
        return [
            AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back),
            AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back),
            AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back),
            wideBackCamera
        ].compactMap { $0 }.first
    }

    private func backCaptureDevice(for factor: CGFloat) -> AVCaptureDevice? {
        if isAutoMacroEnabled, autoMacroUsesUltraWide, factor >= 1,
           let camera = macroCamera, canUseMacroCamera(camera, at: factor) {
            return camera
        }
        return physicalBackLens(for: factor)?.device
    }

    private func canUseMacroCamera(_ camera: AVCaptureDevice, at factor: CGFloat) -> Bool {
        guard let lens = physicalBackLenses.first(where: { $0.device.uniqueID == camera.uniqueID }) else {
            return false
        }
        let deviceZoom = factor / lens.baseZoom
        return deviceZoom >= camera.minAvailableVideoZoomFactor &&
            deviceZoom <= camera.maxAvailableVideoZoomFactor
    }

    // Call while holding the physical device's configuration lock.
    private func configureAutoFocus(on device: AVCaptureDevice) {
        if device.isFocusModeSupported(.continuousAutoFocus),
           device.focusMode != .continuousAutoFocus {
            device.focusMode = .continuousAutoFocus
        }
    }

    // Virtual switch-over factors map each physical lens to the existing UI's zoom scale.
    private var physicalBackLenses: [(device: AVCaptureDevice, baseZoom: CGFloat)] {
        if let camera = backCameraLensMetadata, camera.isVirtualDevice {
            let factors = [CGFloat(1)] + camera.virtualDeviceSwitchOverVideoZoomFactors
                .map { CGFloat(truncating: $0) }
            return zip(camera.constituentDevices, factors).filter { !$0.0.isVirtualDevice }.map { device, factor in
                (device: device, baseZoom: factor * camera.displayVideoZoomFactorMultiplier)
            }
        }
        var lenses: [(device: AVCaptureDevice, baseZoom: CGFloat)] = []
        if let ultraWideCamera { lenses.append((ultraWideCamera, 0.5)) }
        if let wideBackCamera { lenses.append((wideBackCamera, 1)) }
        return lenses
    }

    private func physicalBackLens(for factor: CGFloat) -> (device: AVCaptureDevice, baseZoom: CGFloat)? {
        let lenses = physicalBackLenses.sorted { $0.baseZoom < $1.baseZoom }
        return lenses.last(where: { $0.baseZoom <= factor + 0.01 }) ?? lenses.first
    }

    @discardableResult
    private func applyBackZoom(_ factor: CGFloat) -> Bool {
        guard let device = backCaptureDevice(for: factor),
              !device.isVirtualDevice,
              let currentDevice = videoInput?.device else { return false }
        if device.uniqueID != currentDevice.uniqueID,
           !replaceVideoInput(with: device) { return false }
        let baseZoom = physicalBackLenses.first(where: { $0.device.uniqueID == device.uniqueID })?.baseZoom ?? 1
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            configureAutoFocus(on: device)
            let deviceZoom = factor / baseZoom
            guard !autoMacroUsesUltraWide ||
                    (deviceZoom >= device.minAvailableVideoZoomFactor &&
                     deviceZoom <= device.maxAvailableVideoZoomFactor) else {
                errorMessage = "The selected zoom is unavailable for the macro camera."
                return false
            }
            let requestedZoom = min(
                max(deviceZoom, device.minAvailableVideoZoomFactor),
                device.maxAvailableVideoZoomFactor
            )
            if device.videoZoomFactor != requestedZoom {
                device.videoZoomFactor = requestedZoom
            }
            zoomFactor = device.videoZoomFactor * baseZoom
            refreshMacroState()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
    private var videoInput: AVCaptureDeviceInput?
    private var captureRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var isConfigured = false
    private var wantsRunning = false
    private let sessionRequestState = CameraSessionRequestState()
    private var sessionRequestID: UUID?
    private var sessionStartPending = false
    private var stopQueued = false
    private var sessionLifecycleSubscriptions: [AnyCancellable] = []
    private var shouldResetZoomOnStart = true
    private var autoMacroTask: Task<Void, Never>?
    private var autoMacroUsesUltraWide = false
    private var autoMacroCandidateSince: TimeInterval?
    private var autoMacroCandidateDeviceID: String?
    private enum AutoMacroDecision: Equatable { case enter, exit }
    private var autoMacroCandidateDecision: AutoMacroDecision?
    private var autoMacroLastSampleTime: TimeInterval?
    private var autoMacroNextEvaluationTime: TimeInterval = 0
    private var autoMacroFocusBaseline: Float?
    private var autoMacroFocusDeviceID: String?
    private var autoMacroBaselineCandidatePosition: Float?
    private var autoMacroBaselineCandidateSince: TimeInterval?
    private var autoMacroBaselineLastSampleTime: TimeInterval?
    private var autoMacroStartupSettled = false
    // Heuristics, not distances: each lens needs validation on the target device.
    private let autoMacroEntryLensPosition: Float = 0.12
    private let autoMacroExitLensPositionChange: Float = 0.04
    // Empirical upper bound from supplied device traces; not a measured distance.
    private let autoMacroExitLensPositionCap: Float = 0.80
    private let locationManager = CLLocationManager()
    private var latestLocation: CLLocation?
    private var photoLocation: CLLocation?
    private var photoDateTimeText: String?
    private var videoCaptureDetails: VideoCaptureDetails?
    @Published private var hasRecordingStarted = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        observeSessionLifecycle()
    }

    deinit {
        autoMacroTask?.cancel()
    }

    private func observeSessionLifecycle() {
        let center = NotificationCenter.default
        sessionLifecycleSubscriptions.append(
            center.publisher(for: AVCaptureSession.wasInterruptedNotification, object: session)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.isReady = false
                        self.stopAutoMacroMonitoring()
                        if self.errorMessage == "Could not start the camera." {
                            self.errorMessage = nil
                        }
                    }
                }
        )
        sessionLifecycleSubscriptions.append(
            center.publisher(for: AVCaptureSession.interruptionEndedNotification, object: session)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard self.wantsRunning,
                              UIApplication.shared.applicationState == .active else { return }
                        if self.session.isRunning {
                            self.updateSessionReadiness()
                        } else if !self.isRecording {
                            await self.start()
                        }
                    }
                }
        )
        sessionLifecycleSubscriptions.append(
            center.publisher(for: AVCaptureSession.didStartRunningNotification, object: session)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.updateSessionReadiness() }
                }
        )
        sessionLifecycleSubscriptions.append(
            center.publisher(for: AVCaptureSession.runtimeErrorNotification, object: session)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.isReady = false
                        self?.stopAutoMacroMonitoring()
                    }
                }
        )
    }

    private func updateSessionReadiness() {
        let wasReady = isReady
        isReady = wantsRunning && !sessionStartPending && session.isRunning && !session.isInterrupted &&
            UIApplication.shared.applicationState == .active
        guard isReady else { return }
        if errorMessage == "Could not start the camera." { errorMessage = nil }
        if !wasReady, let device = videoInput?.device {
            applyCameraControls(to: device, enabled: true)
            startAutoMacroMonitoring()
        }
    }

    private func updateLocationTracking() {
        guard wantsRunning, isAuthorized else {
            locationManager.stopUpdatingLocation()
            latestLocation = nil
            return
        }
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.startUpdatingLocation()
        default:
            locationManager.stopUpdatingLocation()
            latestLocation = nil
        }
    }

    func start() async {
        guard !Task.isCancelled else { return }
        wantsRunning = true
        guard !isRecording else { return }
        let requestID = UUID()
        sessionRequestID = requestID
        sessionRequestState.replace(with: requestID)
        sessionStartPending = true
        stopQueued = false
        isReady = false
        isCameraAccessDenied = false
        let videoAllowed = await requestPermission(for: .video)
        guard canContinueStart(requestID) else { return }
        guard videoAllowed else {
            sessionStartPending = false
            isAuthorized = false
            isCameraAccessDenied = true
            isReady = false
            errorMessage = "Camera access is required to capture photos and videos."
            return
        }
        let audioAllowed = await requestPermission(for: .audio)
        guard canContinueStart(requestID) else { return }
        guard UIApplication.shared.applicationState == .active else {
            sessionStartPending = false
            return
        }
        // Finish any already executing shutdown before configuring or restoring
        // controls. Awaiting this queue leaves the UI free to show Library.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { continuation.resume() }
        }
        guard canContinueStart(requestID) else { return }
        guard UIApplication.shared.applicationState == .active else {
            sessionStartPending = false
            return
        }
        isAuthorized = true
        updateLocationTracking()
        if !isConfigured {
            do { try configure(includeAudio: audioAllowed) }
            catch {
                sessionStartPending = false
                errorMessage = error.localizedDescription
                return
            }
        }
        // Apply the requested zoom after configuration, before preview frames start.
        if shouldResetZoomOnStart {
            shouldResetZoomOnStart = false
            resetZoomToOne()
        }
        let captureSession = session
        let requestState = sessionRequestState
        sessionQueue.async {
            guard requestState.isCurrent(requestID) else { return }
            if !captureSession.isRunning { captureSession.startRunning() }
            Task { @MainActor in
                guard self.sessionRequestID == requestID, self.wantsRunning else { return }
                self.sessionStartPending = false
                self.updateSessionReadiness()
                if self.wantsRunning && !captureSession.isRunning &&
                    !captureSession.isInterrupted && UIApplication.shared.applicationState == .active {
                    self.errorMessage = "Could not start the camera."
                }
            }
        }
    }

    private func canContinueStart(_ requestID: UUID) -> Bool {
        guard sessionRequestID == requestID, wantsRunning else { return false }
        guard !Task.isCancelled else {
            stop()
            return false
        }
        return true
    }

    func resetZoomOnNextStart() {
        shouldResetZoomOnStart = true
    }

    func stop() {
        wantsRunning = false
        stopAutoMacroMonitoring()
        updateLocationTracking()
        guard !isRecording else {
            return
        }
        isReady = false
        sessionStartPending = false
        guard !stopQueued else {
            return
        }
        stopQueued = true
        let requestID = UUID()
        sessionRequestID = requestID
        sessionRequestState.replace(with: requestID)
        let requestState = sessionRequestState
        let device = videoInput?.device
        let captureSession = session
        sessionQueue.async {
            guard requestState.isCurrent(requestID) else {
                return
            }
            var cleanupError: String?
            if let device {
                do { try Self.resetStoppedCameraControls(on: device) }
                catch { cleanupError = error.localizedDescription }
            }
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
            if let cleanupError {
                Task { @MainActor in
                    guard self.sessionRequestID == requestID, !self.wantsRunning else { return }
                    self.errorMessage = cleanupError
                }
            }
        }
    }

    // Shutdown uses device state only; published preferences stay on MainActor.
    nonisolated private static func resetStoppedCameraControls(on device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.hasTorch, device.isTorchModeSupported(.off), device.torchMode != .off {
            device.torchMode = .off
        }
        let neutralBias = min(max(Float(0), device.minExposureTargetBias), device.maxExposureTargetBias)
        if device.isExposureModeSupported(.continuousAutoExposure), device.exposureTargetBias != neutralBias {
            device.setExposureTargetBias(neutralBias, completionHandler: nil)
        }
    }

    func takePhoto(shutterSoundEnabled: Bool, dateTimeStampEnabled: Bool) {
        guard isReady, !isBusy, !isRecording else { return }
        guard videoInput?.device.isVirtualDevice == false else {
            errorMessage = "Virtual cameras are not allowed."
            return
        }
        guard photoOutput.availablePhotoCodecTypes.contains(.hevc) else {
            errorMessage = "This device does not support HEIC photo capture."
            return
        }
        guard let connection = photoOutput.connection(with: .video),
              let captureRotationCoordinator else {
            errorMessage = "The photo capture orientation is unavailable."
            return
        }
        // Capture follows the handset's physical orientation, independently of
        // the camera page's fixed portrait preview. PhotoOutput writes EXIF tags.
        let angle = captureRotationCoordinator.videoRotationAngleForHorizonLevelCapture
        guard connection.isVideoRotationAngleSupported(angle) else {
            errorMessage = "The photo capture orientation is unsupported."
            return
        }
        connection.videoRotationAngle = angle
        isBusy = true
        // Snapshot the fix at the shutter, never attach a later or stale location.
        photoLocation = nil
        if let location = latestLocation,
           locationManager.authorizationStatus == .authorizedWhenInUse ||
            locationManager.authorizationStatus == .authorizedAlways {
            let age = Date().timeIntervalSince(location.timestamp)
            if age >= 0, age <= 30, location.horizontalAccuracy >= 0,
               location.horizontalAccuracy.isFinite,
               CLLocationCoordinate2DIsValid(location.coordinate) {
                photoLocation = location
            }
        }
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.photoQualityPrioritization = .quality
        if supportedFlashModes.contains(flashMode) { settings.flashMode = flashMode }
        if !shutterSoundEnabled && photoOutput.isShutterSoundSuppressionSupported {
            settings.isShutterSoundSuppressionEnabled = true
        }
        // Snapshot both the local time and the option at the actual shutter,
        // after any countdown, rather than when processing finishes.
        photoDateTimeText = dateTimeStampEnabled ? PhotoDateTimeStamp.text(for: Date()) : nil
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func startRecording() {
        guard mode == .video, isReady, !isBusy, !isRecording else { return }
        guard let device = videoInput?.device else { return }
        guard !device.isVirtualDevice else {
            errorMessage = "Virtual cameras are not allowed."
            return
        }
        guard configuredVideoDeviceID == device.uniqueID,
              let format = configuredVideoFormat, device.activeFormat === format,
              let colorSpace = configuredVideoColorSpace, device.activeColorSpace == colorSpace,
              let codec = configuredVideoCodec else {
            errorMessage = "Recording is unavailable for this camera configuration. Select another lens or return to Photo and try Video again."
            return
        }
        guard let connection = movieOutput.connection(with: .video),
              movieOutput.availableVideoCodecTypes.contains(codec) else {
            errorMessage = "This camera configuration does not support the selected video codec. Select another lens and try again."
            return
        }
        guard let captureRotationCoordinator else {
            errorMessage = "The video capture orientation is unavailable."
            return
        }
        // Snapshot the handset's orientation at recording start, independently of
        // the fixed portrait preview. MovieFileOutput writes the MOV track transform.
        let angle = captureRotationCoordinator.videoRotationAngleForHorizonLevelCapture
        guard connection.isVideoRotationAngleSupported(angle) else {
            errorMessage = "The video capture orientation is unsupported."
            return
        }
        connection.videoRotationAngle = angle
        movieOutput.setOutputSettings([AVVideoCodecKey: codec], for: connection)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("MOV")
        hasRecordingStarted = false
        let captureDetails = recordingCaptureDetails()
        videoCaptureDetails = captureDetails
        configureMovieMetadata(captureDetails: captureDetails)
        isRecording = true
        movieOutput.startRecording(to: temporaryURL, recordingDelegate: self)
    }

    func stopRecording() {
        guard isRecording else { return }
        isBusy = true
        movieOutput.stopRecording()
    }

    private func configureMovieMetadata(captureDetails: VideoCaptureDetails) {
        let deviceName = VideoCaptureDetails.deviceDisplayName(captureDetails.device)
        let model = deviceName.hasPrefix("Apple ") ? String(deviceName.dropFirst(6)) : deviceName
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.timeZone = .current
        var values: [(AVMetadataIdentifier, String)] = [
            (.quickTimeMetadataMake, "Apple"),
            (.quickTimeMetadataModel, model),
            (.quickTimeMetadataCreationDate, dateFormatter.string(from: captureDetails.capturedAt))
        ]
        if let latitude = captureDetails.latitude, let longitude = captureDetails.longitude,
           latitude.isFinite, longitude.isFinite,
           CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) {
            let location = String(format: "%+09.5f%+010.5f/", locale: Locale(identifier: "en_US_POSIX"),
                                  latitude, longitude)
            values.append((.quickTimeMetadataLocationISO6709, location))
        }
        // Clear the previous movie's location even when this capture has no valid fix.
        var identifiers = Set(values.map { $0.0 })
        identifiers.insert(.quickTimeMetadataLocationISO6709)
        // Replace only our top-level fields. Lens and Dolby Vision track metadata
        // remain generated by MovieFileOutput from the actual capture configuration.
        let existingMetadata = (movieOutput.metadata ?? []).filter { item in
            guard let identifier = item.identifier else { return true }
            return !identifiers.contains(identifier)
        }
        movieOutput.metadata = existingMetadata + values.map { identifier, value -> AVMetadataItem in
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            item.value = value as NSString
            return item
        }
    }

    private func recordingCaptureDetails() -> VideoCaptureDetails {
        let capturedAt = Date()
        let device = videoInput?.device
        // A movie can use multiple lenses. Do not describe the entire recording
        // with the lens, aperture, or focal length observed only at its start.
        let physicalDevice = device?.isVirtualDevice == true ? nil : device
        let lens: String?
        if let physicalDevice {
            switch physicalDevice.deviceType {
            case .builtInWideAngleCamera:
                lens = physicalDevice.position == .front ? "Front Camera" : "Main Camera"
            case .builtInUltraWideCamera: lens = "Ultra Wide Camera"
            case .builtInTelephotoCamera: lens = "Telephoto Camera"
            case .builtInTrueDepthCamera: lens = "TrueDepth Camera"
            default: lens = physicalDevice.localizedName
            }
        } else {
            lens = nil
        }
        let aperture = physicalDevice.map { Double($0.lensAperture) }
        // This is the physical lens's nominal equivalent, not a computed video crop/zoom value.
        let focalLength = physicalDevice.map { Double($0.nominalFocalLengthIn35mmFilm) }
        var location: CLLocation?
        if locationManager.authorizationStatus == .authorizedWhenInUse ||
            locationManager.authorizationStatus == .authorizedAlways,
           let fix = latestLocation {
            let age = capturedAt.timeIntervalSince(fix.timestamp)
            if age >= 0, age <= 30, fix.horizontalAccuracy >= 0,
               fix.horizontalAccuracy.isFinite, CLLocationCoordinate2DIsValid(fix.coordinate) {
                location = fix
            }
        }
        var system = utsname()
        let hardware: String
        if uname(&system) == 0 {
            let capacity = MemoryLayout.size(ofValue: system.machine)
            hardware = withUnsafePointer(to: &system.machine) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(cString: $0)
                }
            }
        } else {
            hardware = ""
        }
        let deviceName = "Apple \(UIDevice.current.model)" + (hardware.isEmpty ? "" : " (\(hardware))")
        return VideoCaptureDetails(
            capturedAt: capturedAt,
            device: deviceName,
            lens: lens,
            focalLength35mm: focalLength.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
            aperture: aperture.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude
        )
    }

    func setFlashMode(_ mode: AVCaptureDevice.FlashMode) {
        guard hasFlash, supportedFlashModes.contains(mode), !isBusy, !isRecording else { return }
        flashMode = mode
    }

    func setVideoTorchMode(_ torchMode: AVCaptureDevice.TorchMode) {
        guard mode == .video, isReady, !isBusy, !isRecording,
              supportedVideoTorchModes.contains(torchMode), let device = videoInput?.device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.torchMode = torchMode
            videoTorchMode = torchMode
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setExposureBias(_ bias: Float) {
        guard isReady, !isBusy, !isRecording,
              bias.isFinite, canAdjustExposure, let device = videoInput?.device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let value = min(max(bias, exposureRange.lowerBound), exposureRange.upperBound)
            device.exposureMode = .continuousAutoExposure
            device.setExposureTargetBias(value, completionHandler: nil)
            storeExposureBias(value)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Restore each mode's exposure on the active camera; torch belongs to VIDEO only.
    private func applyCameraControls(to device: AVCaptureDevice, enabled: Bool) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if enabled { configureAutoFocus(on: device) }
            if device.hasTorch {
                let videoEnabled = enabled && mode == .video
                let requestedMode: AVCaptureDevice.TorchMode = videoEnabled ? videoTorchMode : .off
                let supported = device.isTorchModeSupported(requestedMode) &&
                    (requestedMode == .off || device.isTorchAvailable)
                let appliedMode: AVCaptureDevice.TorchMode = supported ? requestedMode : .off
                if device.isTorchModeSupported(appliedMode), device.torchMode != appliedMode {
                    device.torchMode = appliedMode
                }
                if videoEnabled { videoTorchMode = appliedMode }
            } else if enabled && mode == .video {
                videoTorchMode = .off
            }
            let range = enabled ? exposureRange : device.minExposureTargetBias...device.maxExposureTargetBias
            let value = min(max(enabled ? exposureBias : 0, range.lowerBound), range.upperBound)
            if device.isExposureModeSupported(.continuousAutoExposure) {
                if enabled, device.exposureMode != .continuousAutoExposure {
                    device.exposureMode = .continuousAutoExposure
                }
                if device.exposureTargetBias != value {
                    device.setExposureTargetBias(value, completionHandler: nil)
                }
                if enabled { storeExposureBias(value) }
            } else if enabled {
                storeExposureBias(0)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setZoomFactor(_ factor: CGFloat) {
        guard isReady, !isBusy, !isRecording,
              availableZoomFactors.contains(factor) else { return }
        updateZoomFactor(factor)
    }

    private func updateZoomFactor(_ factor: CGFloat) {
        guard let currentDevice = videoInput?.device else { return }
        if cameraPosition == .back {
            let previousMacroSelection = autoMacroUsesUltraWide
            resetAutoMacroEpisode()
            autoMacroUsesUltraWide = false
            resetAutoMacroDecision(cooldown: 2)
            if !applyBackZoom(factor) {
                autoMacroUsesUltraWide = previousMacroSelection
                refreshMacroState()
            }
            return
        }

        let device = currentDevice

        do {
            try device.lockForConfiguration()
            let requestedFactor = factor / device.displayVideoZoomFactorMultiplier
            let requestedZoom = min(
                max(requestedFactor, device.minAvailableVideoZoomFactor),
                device.maxAvailableVideoZoomFactor
            )
            if device.videoZoomFactor != requestedZoom {
                device.videoZoomFactor = requestedZoom
            }
            device.unlockForConfiguration()
            zoomFactor = factor
            refreshMacroState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func switchCamera() {
        guard isConfigured, isReady, !isBusy, !isRecording else { return }
        let nextPosition: AVCaptureDevice.Position = cameraPosition == .back ? .front : .back
        let nextDevice = nextPosition == .back
            ? backCaptureDevice(for: 1)
            : AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        guard let device = nextDevice else {
            errorMessage = "The selected camera is unavailable."
            return
        }
        if replaceVideoInput(with: device) {
            resetAutoMacroEpisode()
            autoMacroUsesUltraWide = false
            cameraPosition = nextPosition
            resetZoomToOne()
        }
    }

    private func resetZoomToOne() {
        guard let currentDevice = videoInput?.device else { return }
        resetAutoMacroEpisode()
        if cameraPosition == .back {
            autoMacroUsesUltraWide = false
            resetAutoMacroDecision(cooldown: 2)
            applyBackZoom(1)
            return
        }
        let device = currentDevice
        do {
            try device.lockForConfiguration()
            let requestedZoom = min(
                max(1 / device.displayVideoZoomFactorMultiplier, device.minAvailableVideoZoomFactor),
                device.maxAvailableVideoZoomFactor
            )
            if device.videoZoomFactor != requestedZoom {
                device.videoZoomFactor = requestedZoom
            }
            device.unlockForConfiguration()
            zoomFactor = device.videoZoomFactor * device.displayVideoZoomFactorMultiplier
            refreshMacroState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleMacro() {
        guard isConfigured, isReady, !isBusy, !isRecording, isMacroAvailable else { return }
        let previousMacroSelection = autoMacroUsesUltraWide
        resetAutoMacroEpisode()
        isAutoMacroEnabled.toggle()
        autoMacroUsesUltraWide = false
        resetAutoMacroDecision(cooldown: 2)
        if !applyBackZoom(zoomFactor) {
            isAutoMacroEnabled.toggle()
            autoMacroUsesUltraWide = previousMacroSelection
            refreshMacroState()
        }
    }

    private func startAutoMacroMonitoring() {
        stopAutoMacroMonitoring()
        resetAutoMacroDecision(cooldown: 2)
        autoMacroTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) }
                catch { return }
                guard !Task.isCancelled, self != nil else { return }
                self?.evaluateAutoMacro()
            }
        }
    }

    private func stopAutoMacroMonitoring() {
        autoMacroTask?.cancel()
        autoMacroTask = nil
        resetAutoMacroDecision()
        resetAutoMacroBaselineCandidate()
    }

    private func resetAutoMacroDecision(cooldown: TimeInterval = 0) {
        autoMacroCandidateSince = nil
        autoMacroCandidateDeviceID = nil
        autoMacroCandidateDecision = nil
        autoMacroLastSampleTime = nil
        if cooldown > 0 {
            autoMacroNextEvaluationTime = ProcessInfo.processInfo.systemUptime + cooldown
        }
    }

    private func resetAutoMacroBaselineCandidate() {
        autoMacroBaselineCandidatePosition = nil
        autoMacroBaselineCandidateSince = nil
        autoMacroBaselineLastSampleTime = nil
    }

    private func resetAutoMacroFocusBaseline() {
        autoMacroFocusBaseline = nil
        autoMacroFocusDeviceID = nil
        autoMacroStartupSettled = false
        resetAutoMacroBaselineCandidate()
    }

    private func resetAutoMacroEpisode() {
        resetAutoMacroFocusBaseline()
    }

    private func autoMacroDecisionHasSettled(
        _ decision: AutoMacroDecision, deviceID: String, now: TimeInterval, dwell: TimeInterval
    ) -> Bool {
        if autoMacroCandidateDeviceID != deviceID || autoMacroCandidateDecision != decision ||
            autoMacroLastSampleTime.map({ now - $0 > 0.5 }) == true {
            autoMacroCandidateDeviceID = deviceID
            autoMacroCandidateDecision = decision
            autoMacroCandidateSince = now
        }
        autoMacroLastSampleTime = now
        return autoMacroCandidateSince.map { now - $0 >= dwell } ?? false
    }

    private func updateAutoMacroFocusBaseline(_ position: Float, now: TimeInterval) {
        // Track settled readings without treating initial autofocus travel as
        // subject movement. Establish the baseline only after startup settles.
        if autoMacroBaselineCandidatePosition.map({ abs(position - $0) > 0.02 }) != false ||
            autoMacroBaselineLastSampleTime.map({ now - $0 > 0.5 }) == true {
            autoMacroBaselineCandidatePosition = position
            autoMacroBaselineCandidateSince = now
        }
        autoMacroBaselineLastSampleTime = now
        guard let since = autoMacroBaselineCandidateSince,
              now - since >= 0.5,
              let candidate = autoMacroBaselineCandidatePosition else { return }
        let stablePosition = (candidate + position) / 2
        if autoMacroStartupSettled {
            // After startup, only lower the baseline so it cannot chase a
            // subject moving farther away.
            autoMacroFocusBaseline = min(autoMacroFocusBaseline ?? stablePosition, stablePosition)
        }
    }

    private func settleAutoMacroStartup(position: Float, now: TimeInterval) -> Bool {
        guard !autoMacroStartupSettled else { return true }
        // Stay on the ultra-wide input through the existing switch cooldown
        // and a full second of settled samples. Initial AF travel is not an exit.
        guard let since = autoMacroBaselineCandidateSince, now - since >= 1,
              let candidate = autoMacroBaselineCandidatePosition else {
            resetAutoMacroDecision()
            return false
        }
        let settledPosition = (candidate + position) / 2
        autoMacroStartupSettled = true
        autoMacroFocusBaseline = settledPosition
        resetAutoMacroDecision()
        return true
    }

    private var autoMacroExitThreshold: Float? {
        autoMacroFocusBaseline.map { min(autoMacroExitLensPositionCap, $0 + autoMacroExitLensPositionChange) }
    }

    private func evaluateAutoMacro() {
        let now = ProcessInfo.processInfo.systemUptime
        guard wantsRunning, isReady, session.isRunning,
              UIApplication.shared.applicationState == .active,
              isAutoMacroEnabled, isMacroAvailable, cameraPosition == .back,
              !isBusy, !isRecording, !movieOutput.isRecording, zoomFactor >= 1,
              let device = videoInput?.device, !device.isVirtualDevice,
              let macroCamera, canUseMacroCamera(macroCamera, at: zoomFactor) else {
            resetAutoMacroDecision()
            resetAutoMacroBaselineCandidate()
            return
        }
        let isUsingMacroLens = device.uniqueID == macroCamera.uniqueID
        guard isUsingMacroLens == autoMacroUsesUltraWide else {
            autoMacroUsesUltraWide = isUsingMacroLens
            resetAutoMacroDecision(cooldown: 2)
            return
        }
        let position = device.lensPosition
        if isUsingMacroLens {
            if autoMacroFocusDeviceID != device.uniqueID {
                resetAutoMacroFocusBaseline()
                autoMacroFocusDeviceID = device.uniqueID
            }
        }
        guard device.focusMode == .continuousAutoFocus, !device.isAdjustingFocus,
              position.isFinite, (0...1).contains(position) else {
            resetAutoMacroDecision()
            resetAutoMacroBaselineCandidate()
            return
        }
        // Track convergence during cooldown; exit cannot run until the
        // startup baseline has been established on this physical input.
        if isUsingMacroLens { updateAutoMacroFocusBaseline(position, now: now) }
        guard now >= autoMacroNextEvaluationTime else {
            resetAutoMacroDecision()
            return
        }
        if isUsingMacroLens, !settleAutoMacroStartup(position: position, now: now) { return }
        // 0 is the near end, 1 the far end. Values cannot be converted to centimeters
        // or compared as equal distances across the normal and ultra-wide lenses.
        let shouldSwitch: Bool
        if isUsingMacroLens {
            guard let threshold = autoMacroExitThreshold else {
                resetAutoMacroDecision()
                return
            }
            shouldSwitch = position >= threshold
        } else {
            shouldSwitch = position <= autoMacroEntryLensPosition
        }
        guard shouldSwitch else {
            resetAutoMacroDecision()
            return
        }
        let dwell: TimeInterval = isUsingMacroLens ? 1.25 : 0.75
        guard autoMacroDecisionHasSettled(
            isUsingMacroLens ? .exit : .enter, deviceID: device.uniqueID, now: now, dwell: dwell
        ) else { return }

        let previousSelection = autoMacroUsesUltraWide
        let factor = zoomFactor
        let previousFlashMode = flashMode
        autoMacroUsesUltraWide = !previousSelection
        if applyBackZoom(factor) {
            if !isMacroEnabled { resetAutoMacroEpisode() }
        } else {
            autoMacroUsesUltraWide = previousSelection
            // Restore the prior physical lens if input replacement succeeded but
            // configuring its zoom failed. Never fall back to a virtual device.
            applyBackZoom(factor)
            refreshMacroState()
            autoMacroUsesUltraWide = videoInput?.device.uniqueID == macroCamera.uniqueID
        }
        setFlashMode(previousFlashMode)
        resetAutoMacroDecision(cooldown: 2)
    }

    private func refreshMacroState() {
        guard cameraPosition == .back, let device = videoInput?.device, zoomFactor >= 1,
              let macroCamera else {
            isMacroEnabled = false
            return
        }
        isMacroEnabled = device.uniqueID == macroCamera.uniqueID
    }

    private func replaceVideoInput(with device: AVCaptureDevice) -> Bool {
        guard !device.isVirtualDevice else {
            errorMessage = "Virtual cameras are not allowed."
            return false
        }
        guard !isBusy, !isRecording, !movieOutput.isRecording,
              let currentInput = videoInput else { return false }
        do {
            let nextInput = try AVCaptureDeviceInput(device: device)
            applyCameraControls(to: currentInput.device, enabled: false)
            session.beginConfiguration()
            // Use a compatible preset while replacing a lens that may not support 4K.
            if mode == .video, session.canSetSessionPreset(.high) {
                session.sessionPreset = .high
            }
            session.removeInput(currentInput)
            if session.canAddInput(nextInput) {
                session.addInput(nextInput)
                if mode == .video { configureVideoResolution(for: device) }
                configurePhotoResolution(for: device)
                session.commitConfiguration()
                videoInput = nextInput
                captureRotationCoordinator = AVCaptureDevice.RotationCoordinator(
                    device: device, previewLayer: nil
                )
                previewDevice = device
                flashMode = .off
                resetAutoMacroFocusBaseline()
                resetAutoMacroDecision(cooldown: 2)
                applyCameraControls(to: device, enabled: isReady)
                return true
            } else {
                session.addInput(currentInput)
                if mode == .video { configureVideoResolution(for: currentInput.device) }
                configurePhotoResolution(for: currentInput.device)
                session.commitConfiguration()
                previewDevice = currentInput.device
                applyCameraControls(to: currentInput.device, enabled: isReady)
                errorMessage = "Could not switch cameras."
                return false
            }
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func requestPermission(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: mediaType)
        default: return false
        }
    }

    private func updateCapturePreset() {
        guard isConfigured, !isRecording else { return }
        session.beginConfiguration()
        if mode == .photo {
            session.automaticallyConfiguresCaptureDeviceForWideColor = true
            if session.outputs.contains(movieOutput) { session.removeOutput(movieOutput) }
            if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        } else {
            if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
            if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) {
                session.addOutput(movieOutput)
            }
            if let device = videoInput?.device { configureVideoResolution(for: device) }
        }
        if let device = videoInput?.device { configurePhotoResolution(for: device) }
        session.commitConfiguration()
        // Restore the appropriate input after a PHOTO/VIDEO preset change.
        updateZoomFactor(zoomFactor)
        previewDevice = videoInput?.device
        if let device = videoInput?.device {
            applyCameraControls(to: device, enabled: isReady)
        }
    }

    // HLG 10-bit capture formats carry Dolby Vision metadata through MovieFileOutput.
    // isVideoHDRSupported describes the separate EDR feature, not 10-bit HLG support.
    private func isDolbyVisionCaptureFormat(_ format: AVCaptureDevice.Format) -> Bool {
        format.supportedColorSpaces.contains(.HLG_BT2020) &&
            CMFormatDescriptionGetMediaSubType(format.formatDescription) ==
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }

    // Call inside session configuration with the selected input and outputs attached.
    private func configureVideoResolution(for device: AVCaptureDevice) {
        // Invalidate first so a failed lens change cannot reuse a previous configuration.
        configuredVideoFormat = nil
        configuredVideoDeviceID = nil
        configuredVideoColorSpace = nil
        configuredVideoCodec = nil
        let formats = device.formats.filter { format in
            format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
            }
        }
        func orderedFormats(_ candidates: [AVCaptureDevice.Format]) -> [AVCaptureDevice.Format] {
            func rank(_ format: AVCaptureDevice.Format) -> (Int, Int64) {
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let priority: Int
                switch (size.width, size.height) {
                case (3840, 2160): priority = 0
                case (1920, 1080): priority = 1
                case (1280, 720): priority = 2
                default: priority = 3
                }
                return (priority, -(Int64(size.width) * Int64(size.height)))
            }
            return candidates.sorted { rank($0) < rank($1) }
        }
        // Preserve the existing 4K/1080p HLG preference; otherwise choose 8-bit SDR.
        let hdrFormats = formats.filter {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return isDolbyVisionCaptureFormat($0) &&
                ((size.width == 3840 && size.height == 2160) ||
                 (size.width == 1920 && size.height == 1080))
        }
        let sdrFormats = formats.filter {
            let pixelFormat = CMFormatDescriptionGetMediaSubType($0.formatDescription)
            return $0.supportedColorSpaces.contains(.sRGB) &&
                (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                 pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            session.automaticallyConfiguresCaptureDeviceForWideColor = false
            session.sessionPreset = .inputPriority
            // Re-evaluate codecs after applying each format; availability is configuration-dependent.
            for (candidates, colorSpace) in [(hdrFormats, AVCaptureColorSpace.HLG_BT2020),
                                             (sdrFormats, AVCaptureColorSpace.sRGB)] {
                for format in orderedFormats(candidates) {
                    device.activeFormat = format
                    device.activeColorSpace = colorSpace
                    let frameDuration = CMTime(value: 1, timescale: 30)
                    device.activeVideoMinFrameDuration = frameDuration
                    device.activeVideoMaxFrameDuration = frameDuration
                    let available = movieOutput.availableVideoCodecTypes
                    let codec: AVVideoCodecType?
                    if available.contains(.hevc) { codec = .hevc }
                    else if colorSpace == .sRGB && available.contains(.h264) { codec = .h264 }
                    else { codec = nil }
                    guard let codec else { continue }
                    configuredVideoFormat = format
                    configuredVideoDeviceID = device.uniqueID
                    configuredVideoColorSpace = colorSpace
                    configuredVideoCodec = codec
                    return
                }
            }
            errorMessage = "This camera cannot record HDR or SDR video at 30 FPS with HEVC or H.264. Select another lens or use Photo mode."
        } catch {
            errorMessage = "Could not configure video recording: \(error.localizedDescription)"
        }
    }

    // Call inside session configuration, after selecting the input and preset.
    private func configurePhotoResolution(for device: AVCaptureDevice) {
        photoOutput.maxPhotoQualityPrioritization = .quality
        guard let dimensions = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }) else { return }
        let current = photoOutput.maxPhotoDimensions
        if current.width != dimensions.width || current.height != dimensions.height {
            photoOutput.maxPhotoDimensions = dimensions
        }
    }

    private func configure(includeAudio: Bool) throws {
        guard let camera = backCaptureDevice(for: 1), !camera.isVirtualDevice else {
            throw CameraError.noCamera
        }
        try camera.lockForConfiguration()
        configureAutoFocus(on: camera)
        camera.unlockForConfiguration()
        let videoInput = try AVCaptureDeviceInput(device: camera)
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            previewDevice = self.videoInput?.device
        }
        session.sessionPreset = mode == .photo ? .photo : .high
        guard session.canAddInput(videoInput),
              session.canAddOutput(photoOutput) else {
            throw CameraError.configurationFailed
        }
        session.addInput(videoInput)
        self.videoInput = videoInput
        captureRotationCoordinator = AVCaptureDevice.RotationCoordinator(
            device: camera, previewLayer: nil
        )
        if includeAudio, let microphone = AVCaptureDevice.default(for: .audio) {
            let audioInput = try AVCaptureDeviceInput(device: microphone)
            if session.canAddInput(audioInput) { session.addInput(audioInput) }
        }
        session.addOutput(photoOutput)
        if mode == .video, session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        if mode == .video { configureVideoResolution(for: camera) }
        configurePhotoResolution(for: camera)
        isConfigured = true
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    private func photoErrorMessage(stage: String, error: Error) -> String {
        let detail = error as NSError
        return "Photo \(stage) failed: \(detail.localizedDescription) [\(detail.domain), code \(detail.code)]"
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        Task { @MainActor in
            defer {
                self.photoLocation = nil
                self.photoDateTimeText = nil
                self.isBusy = false
            }
            var data: Data?
            if error == nil, let location = self.photoLocation {
                data = photo.fileDataRepresentation(with: PhotoMetadataCustomizer(location: location))
            } else {
                data = error == nil ? photo.fileDataRepresentation() : nil
            }
            if let originalData = data, let text = self.photoDateTimeText {
                do {
                    // Full-resolution rendering and HEIC encoding can be costly.
                    data = try await Task.detached(priority: .userInitiated) {
                        try PhotoDateTimeStamp.apply(to: originalData, text: text)
                    }.value
                } catch {
                    self.errorMessage = self.photoErrorMessage(stage: "date and time stamp", error: error)
                    return
                }
            }
            if let error { self.errorMessage = self.photoErrorMessage(stage: "capture processing", error: error) }
            else if let data { self.onPhoto?(data) }
            else { self.errorMessage = "The captured photo could not be converted to file data. Please try taking the photo again." }
        }
    }
}

extension CameraService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.updateLocationTracking() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard self.wantsRunning, self.isAuthorized else { return }
            self.latestLocation = locations.last
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.latestLocation = nil }
    }
}

// Only replace the metadata dictionary; preserve the original image and attachments.
nonisolated private final class PhotoMetadataCustomizer: NSObject, AVCapturePhotoFileDataRepresentationCustomizer {
    let location: CLLocation

    init(location: CLLocation) {
        self.location = location
        super.init()
    }

    func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
        var metadata = photo.metadata
        var gps = metadata[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        gps[kCGImagePropertyGPSLatitude as String] = abs(location.coordinate.latitude)
        gps[kCGImagePropertyGPSLatitudeRef as String] = location.coordinate.latitude < 0 ? "S" : "N"
        gps[kCGImagePropertyGPSLongitude as String] = abs(location.coordinate.longitude)
        gps[kCGImagePropertyGPSLongitudeRef as String] = location.coordinate.longitude < 0 ? "W" : "E"
        gps[kCGImagePropertyGPSHPositioningError as String] = location.horizontalAccuracy
        if location.verticalAccuracy >= 0, location.altitude.isFinite {
            gps[kCGImagePropertyGPSAltitude as String] = abs(location.altitude)
            gps[kCGImagePropertyGPSAltitudeRef as String] = location.altitude < 0 ? 1 : 0
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd"
        gps[kCGImagePropertyGPSDateStamp as String] = formatter.string(from: location.timestamp)
        formatter.dateFormat = "HH:mm:ss.SSS"
        gps[kCGImagePropertyGPSTimeStamp as String] = formatter.string(from: location.timestamp)
        metadata[kCGImagePropertyGPSDictionary as String] = gps
        return metadata
    }
}

extension CameraService: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        Task { @MainActor in
            self.hasRecordingStarted = true
        }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor in
            self.hasRecordingStarted = false
            self.isRecording = false
            self.isBusy = false
            let captureDetails = self.videoCaptureDetails
            self.videoCaptureDetails = nil
            // AVFoundation can report a stop condition while still finishing a valid file.
            let recordedSuccessfully = error == nil ||
                ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? NSNumber)?.boolValue == true
            if recordedSuccessfully {
                self.onVideo?(outputFileURL, captureDetails)
            } else {
                try? FileManager.default.removeItem(at: outputFileURL)
                self.errorMessage = error?.localizedDescription ?? "The video could not be recorded."
            }
        }
    }
}

private enum CameraError: LocalizedError {
    case noCamera
    case configurationFailed

    var errorDescription: String? {
        switch self {
        case .noCamera: "No back camera is available."
        case .configurationFailed: "The camera could not be configured."
        }
    }
}

struct CameraPreview: UIViewControllerRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice?
    // Consult the live route, including when an outgoing hosting controller
    // recreates a preview using an older SwiftUI view value.
    let shouldAttachSession: @MainActor () -> Bool
    var onDeviceOrientationChange: (UIDeviceOrientation) -> Void
    var onWindowSceneChange: (UIWindowScene) -> Void

    func makeUIViewController(context: Context) -> CameraPreviewController {
        let controller = CameraPreviewController()
        controller.onDeviceOrientationChange = onDeviceOrientationChange
        controller.onWindowSceneChange = onWindowSceneChange
        controller.previewView.previewLayer.videoGravity = .resizeAspectFill
        attachSessionIfNeeded(to: controller)
        return controller
    }

    func updateUIViewController(_ controller: CameraPreviewController, context: Context) {
        controller.onDeviceOrientationChange = onDeviceOrientationChange
        controller.onWindowSceneChange = onWindowSceneChange
        attachSessionIfNeeded(to: controller)
    }

    @MainActor
    private func attachSessionIfNeeded(to controller: CameraPreviewController) {
        guard shouldAttachSession() else {
            return
        }
        if controller.previewView.previewLayer.session !== session {
            controller.previewView.previewLayer.session = session
        }
        controller.setPreviewDevice(device)
        controller.updatePreviewOrientation()
    }

    static func dismantleUIViewController(_ controller: CameraPreviewController, coordinator: ()) {
        controller.stopObservingDeviceOrientation()
        controller.stopObservingPreviewLifecycle()
    }
}

final class CameraPreviewController: UIViewController {
    let previewView = PreviewView()
    var onDeviceOrientationChange: ((UIDeviceOrientation) -> Void)?
    var onWindowSceneChange: ((UIWindowScene) -> Void)?
    private var isObservingDeviceOrientation = false
    private var reportedOrientation: UIDeviceOrientation?
    private weak var reportedScene: UIWindowScene?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private let previewCover = UIView()
    private var previewLifecycleSubscriptions: [AnyCancellable] = []
    private var previewResumeDisplayLink: CADisplayLink?
    private var previewResumeDeadline: TimeInterval = 0

    override func loadView() {
        view = previewView
        previewCover.backgroundColor = .black
        previewCover.isUserInteractionEnabled = false
        previewCover.isAccessibilityElement = false
        previewCover.isHidden = true
        previewCover.frame = previewView.bounds
        previewCover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        previewView.addSubview(previewCover)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startObservingDeviceOrientation()
        startObservingPreviewLifecycle()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updatePreviewOrientation()
        waitForLivePreview()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopObservingDeviceOrientation()
        stopObservingPreviewLifecycle()
    }


    private func startObservingPreviewLifecycle() {
        guard previewLifecycleSubscriptions.isEmpty,
              let session = previewView.previewLayer.session else { return }
        let center = NotificationCenter.default
        // Cover the old frame before the app leaves the foreground, including
        // before iOS captures the app's appearance for its return transition.
        previewLifecycleSubscriptions.append(
            center.publisher(for: UIApplication.willResignActiveNotification)
                .sink { [weak self] _ in self?.coverPreview() }
        )
        previewLifecycleSubscriptions.append(
            center.publisher(for: AVCaptureSession.wasInterruptedNotification, object: session)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.coverPreview()
                    self?.waitForLivePreview()
                }
        )
        for (name, object) in [
            (UIApplication.didBecomeActiveNotification, nil as AnyObject?),
            (AVCaptureSession.interruptionEndedNotification, session as AnyObject?),
            (AVCaptureSession.didStartRunningNotification, session as AnyObject?)
        ] {
            previewLifecycleSubscriptions.append(
                center.publisher(for: name, object: object)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in self?.waitForLivePreview() }
            )
        }
        previewLifecycleSubscriptions.append(
            center.publisher(for: AVCaptureSession.runtimeErrorNotification, object: session)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.coverPreview() }
        )
        if previewView.window?.windowScene?.activationState != .foregroundActive {
            coverPreview()
        }
    }

    func stopObservingPreviewLifecycle() {
        previewLifecycleSubscriptions.removeAll()
        previewResumeDisplayLink?.invalidate()
        previewResumeDisplayLink = nil
        previewCover.isHidden = true
    }

    private func coverPreview() {
        previewResumeDisplayLink?.invalidate()
        previewResumeDisplayLink = nil
        previewCover.isHidden = false
    }

    private func waitForLivePreview() {
        guard !previewCover.isHidden, previewResumeDisplayLink == nil,
              previewView.window?.windowScene?.activationState == .foregroundActive else { return }
        previewResumeDeadline = ProcessInfo.processInfo.systemUptime + 3
        let displayLink = CADisplayLink(target: self, selector: #selector(checkLivePreview(_:)))
        previewResumeDisplayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    @objc private func checkLivePreview(_ displayLink: CADisplayLink) {
        guard previewView.window?.windowScene?.activationState == .foregroundActive else {
            displayLink.invalidate()
            previewResumeDisplayLink = nil
            return
        }
        let layer = previewView.previewLayer
        if layer.session?.isRunning == true,
           layer.session?.isInterrupted == false, layer.isPreviewing {
            displayLink.invalidate()
            previewResumeDisplayLink = nil
            previewCover.isHidden = true
        } else if ProcessInfo.processInfo.systemUptime >= previewResumeDeadline {
            // Stop polling on failed recovery, but keep the old frame covered.
            // A subsequent session-start or interruption-ended event retries.
            displayLink.invalidate()
            previewResumeDisplayLink = nil
        }
    }

    private func startObservingDeviceOrientation() {
        guard !isObservingDeviceOrientation else { return }
        isObservingDeviceOrientation = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification, object: nil
        )
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        reportDeviceOrientation()
    }

    func stopObservingDeviceOrientation() {
        guard isObservingDeviceOrientation else { return }
        isObservingDeviceOrientation = false
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    @objc private func deviceOrientationDidChange(_ notification: Notification) {
        reportDeviceOrientation()
    }

    private func reportDeviceOrientation() {
        let orientation = UIDevice.current.orientation
        switch orientation {
        case .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight: break
        default: return // Lying flat should keep the last readable label direction.
        }
        guard reportedOrientation != orientation else { return }
        reportedOrientation = orientation
        DispatchQueue.main.async { [weak self] in
            self?.onDeviceOrientationChange?(orientation)
        }
    }

    func setPreviewDevice(_ device: AVCaptureDevice?) {
        guard let device else {
            rotationCoordinator = nil
            return
        }
        guard rotationCoordinator?.device?.uniqueID != device.uniqueID else { return }
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(
            device: device, previewLayer: previewView.previewLayer
        )
    }

    func updatePreviewOrientation() {
        if let scene = previewView.window?.windowScene, reportedScene !== scene {
            reportedScene = scene
            DispatchQueue.main.async { [weak self, weak scene] in
                guard let scene else { return }
                self?.onWindowSceneChange?(scene)
            }
        }
        // The page uses portrait device coordinates even when the handset turns.
        // Ask the actual camera for its sensor-to-portrait angle, which can differ
        // between front and back cameras. A horizon angle would rotate the image
        // inside this fixed rectangle as well as the physical handset.
        guard let rotationCoordinator,
              let connection = previewView.previewLayer.connection else { return }
        let angle = rotationCoordinator.videoRotationAngleRelative(toDeviceOrientation: .portrait)
        guard connection.isVideoRotationAngleSupported(angle), connection.videoRotationAngle != angle else { return }
        connection.videoRotationAngle = angle
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
