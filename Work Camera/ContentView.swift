import AVFoundation
import AVKit
import Combine
import CoreLocation
import ImageIO
import MapKit
import Photos
import SwiftUI
import UIKit

struct ContentView: View {
    private enum CameraControl: Hashable {
        case flash
        case exposure
        case timer
        case grid
        case shutterSound
        case dateTimeStamp
        case photoQuality
    }

    @ObservedObject var navigation: CameraSceneNavigation
    @StateObject private var store = MediaStore()
    @StateObject private var camera = CameraService()
    @State private var didPrepareRoot = false
    @State private var showGrid = true
    @AppStorage("shutterSoundEnabled") private var shutterSoundEnabled = true
    @AppStorage("photoDateTimeStampEnabled") private var photoDateTimeStampEnabled = false
    @AppStorage("photoQuality") private var photoQuality: CameraService.PhotoQuality = .balanced
    @State private var showCameraControls = false
    @State private var activeControl: CameraControl?
    @State private var timerSeconds = 0
    @State private var countdownRemaining: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var countdownID: UUID?
    @State private var errorMessage: String?
    @State private var deviceOrientation: UIDeviceOrientation = .portrait
    @State private var portraitCameraInsets: UIEdgeInsets?
    @State private var portraitCameraSize: CGSize?

    private var scenePhase: ScenePhase { navigation.scenePhase }
    private var libraryFlowActive: Bool { navigation.libraryVisible }

    var body: some View {
        // A stable container owns lifecycle work across destination changes.
        ZStack {
            if libraryFlowActive {
                NavigationStack {
                    LibraryView(store: store, quickAction: navigation.quickAction) {
                        navigation.returnToCamera()
                    }
                }
            } else if let size = portraitCameraSize {
                cameraPage(size: size)
            } else {
                // Camera entry waits for its first portrait layout.
                Color(uiColor: .systemBackground).ignoresSafeArea()
            }
        }
        .background {
            CameraWindowSceneReader { scene in
                updateCameraScene(scene)
            }
            .frame(width: 0, height: 0)
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil || camera.errorMessage != nil || navigation.errorMessage != nil },
            set: { if !$0 { clearErrors() } }
        )) {
            Button("OK") { clearErrors() }
        } message: {
            Text(errorMessage ?? camera.errorMessage ?? navigation.errorMessage ?? "Unknown error")
        }
        .task {
            guard !didPrepareRoot else { return }
            didPrepareRoot = true
            camera.onPhoto = { data in
                try await store.saveCapturedPhoto(data)
            }
            camera.onVideo = { temporaryURL, captureDetails in
                try await store.saveVideo(from: temporaryURL, captureDetails: captureDetails)
            }
            do { try store.load() }
            catch { errorMessage = error.localizedDescription }
        }
        .onChange(of: shouldKeepScreenAwake, initial: true) { _, keepAwake in
            UIApplication.shared.isIdleTimerDisabled = keepAwake
        }
        .onDisappear {
            cancelCountdown()
            camera.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: libraryFlowActive) { _, isPresented in
            if isPresented {
                cancelCountdown()
                showCameraControls = false
                activeControl = nil
            }
        }
        .onChange(of: camera.mode) { _, newMode in
            if newMode == .video { cancelCountdown() }
            activeControl = nil
            showCameraControls = false
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                cancelCountdown()
            }
            if newPhase == .background { camera.resetZoomOnNextStart() }
        }
        .task(id: shouldKeepScreenAwake) {
            guard !Task.isCancelled else { return }
            // Check the current route inside the task: a queued start must not
            // restart capture after a shortcut has switched the root to Library.
            if shouldKeepScreenAwake {
                await camera.start()
            } else {
                camera.stop()
            }
        }
    }

    private var shouldKeepScreenAwake: Bool {
        scenePhase == .active && portraitCameraSize != nil && !libraryFlowActive
    }

    private func clearErrors() {
        errorMessage = nil
        camera.errorMessage = nil
        navigation.errorMessage = nil
    }

    private func openLibrary() {
        guard !camera.isBusy, !camera.isRecording, countdownRemaining == nil else { return }
        // Coordinate the destination geometry without waiting for camera hardware cleanup.
        navigation.openLibrary()
        cancelCountdown()
    }

    private func updateCameraScene(_ scene: UIWindowScene) {
        navigation.attach(to: scene)
        guard portraitCameraSize == nil,
              scene.effectiveGeometry.interfaceOrientation == .portrait,
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else { return }
        window.layoutIfNeeded()
        let insets = window.safeAreaInsets
        let size = window.bounds.size
        guard insets != .zero, size.width > 0, size.height > 0,
              size.height >= size.width else { return }
        portraitCameraInsets = insets
        portraitCameraSize = CGSize(width: min(size.width, size.height),
                                    height: max(size.width, size.height))
    }

    // Rotate labels only. Button frames and PHOTO/VIDEO remain in portrait device coordinates.
    private var controlLabelAngle: Angle {
        switch deviceOrientation {
        case .landscapeLeft: .degrees(90)
        case .landscapeRight: .degrees(-90)
        case .portraitUpsideDown: .degrees(180)
        default: .zero
        }
    }

    private func cameraPage(size: CGSize) -> some View {
        FixedPortraitCameraCanvas(
            portraitSize: size,
            content: cameraCanvas(size: size)
        )
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private func cameraCanvas(size: CGSize) -> some View {
        let deviceWidth = size.width
        let deviceHeight = size.height
        let cameraEdgeInset = portraitCameraInsets?.top ?? 0
        let bottomSafeAreaInset = portraitCameraInsets?.bottom ?? 0
        let isVideo = camera.mode == .video
        let previewRatio: CGFloat = camera.mode == .photo ? 4 / 3 : 16 / 9
        let topHeight = isVideo ? cameraEdgeInset : max(max(80, cameraEdgeInset + 52),
            (deviceHeight - deviceWidth * previewRatio) * 0.33)
        let bottomHeight = isVideo ? 76 + bottomSafeAreaInset : 188
        let previewHeight = min(deviceWidth * previewRatio, max(0, deviceHeight - topHeight - bottomHeight))
        let previewWidth = isVideo ? deviceWidth : previewHeight / previewRatio

        return ZStack {
            // The sensor and the fixed portrait preview rotate with the handset.
            cameraPreview()
                .frame(width: previewWidth, height: previewHeight)
                .clipped()
                .position(x: deviceWidth / 2, y: topHeight + previewHeight / 2)

            // Controls retain their original portrait device coordinates.
            VStack(spacing: 0) {
                if isVideo {
                    Color.black.frame(height: topHeight)
                } else {
                    topControls()
                        .padding(.top, cameraEdgeInset)
                        .frame(height: topHeight)
                        .background(.black)
                }

                ZStack(alignment: .bottom) {
                    Color.clear.allowsHitTesting(false)
                    if isVideo {
                        VStack {
                            Text("HEVC")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                                .rotationEffect(controlLabelAngle)
                                .shadow(color: .black.opacity(0.6), radius: 2)
                                .padding(.top, 12)
                                .accessibilityLabel("HEVC video")
                                .opacity(camera.isRecording ? 0 : 1)
                            Spacer(minLength: 0)
                            if camera.isAuthorized {
                                zoomControls()
                                    .padding(.bottom, 124)
                            }
                        }
                    } else if camera.isAuthorized {
                        zoomControls()
                            .padding(.bottom, 12)
                    }
                }
                .frame(height: previewHeight)

                Color.black
                    .frame(maxHeight: .infinity)
            }
            .frame(width: deviceWidth, height: deviceHeight)
            .position(x: deviceWidth / 2, y: deviceHeight / 2)

            bottomControls(bottomSafeAreaInset: bottomSafeAreaInset)
                .frame(width: deviceWidth)
                .frame(height: deviceHeight, alignment: .bottom)

            if isVideo && camera.isRecording {
                recordingTimeBadge
                    .rotationEffect(controlLabelAngle)
                    .position(recordingTimePosition(
                        width: previewWidth,
                        height: previewHeight,
                        top: topHeight
                    ))
                    .allowsHitTesting(false)
            }

            if showCameraControls || activeControl != nil {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        showCameraControls = false
                        activeControl = nil
                    }
                Group {
                    if let activeControl {
                        controlPanel(for: activeControl)
                    } else {
                        cameraControlsPanel
                    }
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, activeControl == nil ? 16 : 8)
                    .padding(.bottom, activeControl == nil ? 16 : 8)
            }
        }
        .frame(width: deviceWidth, height: deviceHeight)
        .background(.black)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .transaction { $0.animation = nil }
    }

    private var recordingTimeBadge: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let seconds = camera.recordingElapsedSeconds
            let time = String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            Text(time)
                .font(.system(size: 22, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(.red, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Recording time")
                .accessibilityValue(time)
        }
    }

    private func recordingTimePosition(width: CGFloat, height: CGFloat, top: CGFloat) -> CGPoint {
        // The camera page stays in portrait coordinates; move the badge to the
        // top edge as seen by the user, then rotate it with the other labels.
        let edgeInset: CGFloat = 30
        switch deviceOrientation {
        case .landscapeLeft:
            return CGPoint(x: width - edgeInset, y: top + height / 2)
        case .landscapeRight:
            return CGPoint(x: edgeInset, y: top + height / 2)
        case .portraitUpsideDown:
            return CGPoint(x: width / 2, y: top + height - edgeInset)
        default:
            return CGPoint(x: width / 2, y: top + edgeInset)
        }
    }

    private func cameraPreview() -> some View {
        ZStack {
            CameraPreview(
                session: camera.session,
                device: camera.previewDevice,
                shouldAttachSession: { [navigation] in
                    !navigation.libraryVisible
                },
                onDeviceOrientationChange: { orientation in
                    if deviceOrientation != orientation {
                        deviceOrientation = orientation
                    }
                },
                onWindowSceneChange: { scene in
                    updateCameraScene(scene)
                }
            )
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let translation = value.translation
                        guard abs(translation.width) >= 50,
                              abs(translation.width) > abs(translation.height),
                              !camera.isBusy,
                              !camera.isRecording,
                              countdownRemaining == nil else { return }
                        camera.mode = translation.width > 0 ? .video : .photo
                    }
            )
            .opacity(camera.isAuthorized ? 1 : 0)
            .allowsHitTesting(camera.isAuthorized)
            if camera.isAuthorized {
                if showGrid { CameraGrid() }
                if let countdownRemaining {
                    Text("\(countdownRemaining)")
                        .font(.system(size: 92, weight: .light, design: .rounded))
                        .rotationEffect(controlLabelAngle)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Photo in \(countdownRemaining) seconds")
                }
            } else if camera.isCameraAccessDenied {
                ContentUnavailableView(
                    "Camera unavailable",
                    systemImage: "camera.fill",
                    description: Text("Allow camera and microphone access in Settings.")
                )
                .foregroundStyle(.white)
            }
        }
    }

    private func topControls() -> some View {
        HStack(spacing: 0) {
            Button {
                showCameraControls = false
                activeControl = .flash
            } label: {
                Image(systemName: camera.flashSymbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(camera.flashMode == .off ? .white : .yellow)
                    .frame(width: 44, height: 44)
                    .overlay(alignment: .bottomTrailing) {
                        if camera.flashMode == .auto {
                            Text("A")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 10, height: 10)
                                .background(.yellow, in: Circle())
                        }
                    }
            }
            .rotationEffect(controlLabelAngle)
            .accessibilityLabel("Flash: \(camera.flashDescription)")
            .disabled(camera.mode != .photo || !camera.hasFlash || camera.isRecording || countdownRemaining != nil)

            Button {
                showCameraControls = false
                activeControl = .timer
            } label: {
                VStack(spacing: 0) {
                    Image(systemName: "timer")
                        .font(.system(size: 20))
                    if timerSeconds > 0 {
                        Text("\(timerSeconds)s")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .frame(width: 44, height: 44)
                .foregroundStyle(timerSeconds > 0 ? .yellow : .white)
            }
            .rotationEffect(controlLabelAngle)
            .accessibilityLabel("Timer: \(timerSeconds == 0 ? "Off" : "\(timerSeconds) seconds")")
            .disabled(camera.mode != .photo || camera.isRecording || countdownRemaining != nil)

            Text(camera.mode == .photo ? "HEIC" : "HEVC")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 44, height: 44)
                .rotationEffect(controlLabelAngle)
                .accessibilityLabel(camera.mode == .photo ? "HEIC photo" : "HEVC video")
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func zoomControls() -> some View {
        HStack(spacing: 12) {
            ForEach(camera.availableZoomFactors, id: \.self) { factor in
                Button { camera.setZoomFactor(factor) } label: {
                    Text(zoomLabel(for: factor))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(abs(camera.zoomFactor - factor) < 0.05 ? .yellow : .white)
                        .rotationEffect(controlLabelAngle)
                        .frame(width: 44, height: 44)
                        .background(abs(camera.zoomFactor - factor) < 0.05 ? .black.opacity(0.55) : .clear, in: Circle())
                }
                .accessibilityLabel("\(factor.formatted()) times zoom")
            }
        }
        .disabled(!camera.isReady || camera.isRecording || countdownRemaining != nil)
    }

    private func zoomLabel(for factor: CGFloat) -> String {
        factor.rounded() == factor ? "\(Int(factor))×" : "\(factor.formatted())×"
    }

    private func bottomControls(bottomSafeAreaInset: CGFloat) -> some View {
        // Native camera proportions: row centers 120pt and 24pt above the safe area.
        VStack(spacing: 32) {
            captureControls
                .frame(height: 80)

            // Keep the library thumbnail alive when switching capture modes.
            modeControls
                .frame(height: 48)
        }
        .padding(.bottom, bottomSafeAreaInset)
        .foregroundStyle(.white)
    }

    private var captureControls: some View {
        HStack {
            macroButton
            Spacer()
            shutterButton
            Spacer()
            controlsButton
        }
        .padding(.horizontal, 34)
        .foregroundStyle(.white)
    }

    private var modeControls: some View {
        HStack(spacing: 10) {
            libraryButton

            HStack(spacing: 2) {
                modeButton(.video, title: "VIDEO")
                modeButton(.photo, title: "PHOTO")
            }
            .padding(2)
            .background(.white.opacity(0.1), in: Capsule())
            .frame(maxWidth: .infinity)

            switchCameraButton
        }
        .padding(.horizontal, 34)
        .foregroundStyle(.white)
    }

    private var macroButton: some View {
        Button { camera.toggleMacro() } label: {
            Image(systemName: "camera.macro")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(camera.isMacroEnabled ? .yellow : .white)
                .overlay {
                    if !camera.isAutoMacroEnabled {
                        Rectangle()
                            .fill(.white)
                            .frame(width: 2, height: 32)
                            .rotationEffect(.degrees(45))
                    }
                }
                .rotationEffect(controlLabelAngle)
                .frame(width: 48, height: 48)
                .background(.white.opacity(0.12), in: Circle())
                .overlay {
                    Circle().strokeBorder(
                        camera.isMacroEnabled ? .yellow : .white.opacity(0.2), lineWidth: 2
                    )
                }
        }
        .accessibilityLabel(camera.isAutoMacroEnabled ? "Turn off Auto Macro" : "Turn on Auto Macro")
        .accessibilityValue(camera.isMacroEnabled ? "Macro active" : "Macro inactive")
        .accessibilityHint("Automatically switches lenses for close subjects in photos and videos")
        .disabled(!camera.isReady || !camera.isMacroAvailable || camera.isBusy || camera.isRecording || countdownRemaining != nil)
    }

    private var shutterButton: some View {
        let isShutterDisabled = countdownRemaining == nil &&
            (camera.mode == .photo ? !camera.canAcceptPhoto : (!camera.isReady || camera.isBusy))
        let photoShutterColor: Color = isShutterDisabled ? .white.opacity(0.35) : .white
        return Button { shutterTapped() } label: {
            ZStack {
                Circle().strokeBorder(.white.opacity(0.35), lineWidth: 5).frame(width: 80, height: 80)
                // Keep the light on until submitted photos finish processing/saving.
                // Completion presentation delays do not extend this indicator.
                if camera.pendingPhotoCount > 0 || camera.isBusy {
                    Circle()
                        .strokeBorder(camera.mode == .video ? Color.red : Color.white, lineWidth: 5)
                        .frame(width: 80, height: 80)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if camera.isRecording {
                    RoundedRectangle(cornerRadius: 5).fill(.red).frame(width: 30, height: 30)
                } else {
                    Circle().fill(camera.mode == .video ? .red : photoShutterColor).frame(width: 68, height: 68)
                }
            }
        }
        .accessibilityLabel(countdownRemaining != nil ? "Cancel timer" : camera.isRecording ? "Stop recording" : camera.mode == .video ? "Record video" : "Take photo")
        .accessibilityValue(camera.pendingPhotoCount > 0 ? "\(camera.pendingPhotoCount) photos processing" : camera.isBusy ? "Processing video" : "")
        .disabled(isShutterDisabled)
    }

    private var controlsButton: some View {
        Button {
            activeControl = nil
            showCameraControls = true
        } label: {
            Image(systemName: "circle.grid.3x3.fill")
                .font(.system(size: 23))
                .rotationEffect(controlLabelAngle)
                .frame(width: 48, height: 48)
                .background(.white.opacity(0.12), in: Circle())
                .overlay(Circle().strokeBorder(.yellow, lineWidth: 2))
        }
        .accessibilityLabel("Camera controls")
    }

    private var libraryButton: some View {
        Button { openLibrary() } label: {
            ZStack {
                Circle().fill(.white.opacity(0.12))
                if let item = store.items.first {
                    MediaThumbnail(item: item)
                        .frame(width: 48, height: 48)
                        .clipped()
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title3)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(Circle())
            .rotationEffect(controlLabelAngle)
        }
        .accessibilityLabel("Open Library")
        .disabled(camera.isBusy || camera.isRecording || countdownRemaining != nil)
    }

    private var switchCameraButton: some View {
        Button { camera.switchCamera() } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 25))
                .rotationEffect(controlLabelAngle)
                .frame(width: 48, height: 48)
                .background(.white.opacity(0.12), in: Circle())
        }
        .accessibilityLabel(camera.cameraPosition == .back ? "Switch to front camera" : "Switch to back camera")
        .disabled(!camera.isReady || camera.isBusy || camera.isRecording || countdownRemaining != nil)
    }

    private var cameraControlsPanel: some View {
        VStack(spacing: 28) {
            Capsule()
                .fill(.white.opacity(0.55))
                .frame(width: 48, height: 5)

            if camera.mode == .video {
                HStack(alignment: .top, spacing: 24) {
                    videoControlButton(.flash, title: "FLASH",
                                       symbol: camera.videoTorchMode == .off ? "bolt.slash.fill" : "bolt.fill",
                                       value: camera.videoTorchDescription)
                        .disabled(camera.supportedVideoTorchModes.isEmpty)
                    videoControlButton(.exposure, title: "EXPOSURE", symbol: "plusminus",
                                       value: exposureLabel)
                        .disabled(!camera.canAdjustExposure)
                }
                .disabled(!camera.isReady || camera.isBusy || camera.isRecording)
            } else {
                photoControlsPanelContent
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 32)
        .frame(maxWidth: 500)
        .background(Color(white: 0.13).opacity(0.97), in: RoundedRectangle(cornerRadius: 36))
        .overlay(RoundedRectangle(cornerRadius: 36).strokeBorder(.white.opacity(0.2)))
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            if value.translation.height > 50 { showCameraControls = false }
        })
        .accessibilityAction(.escape) { showCameraControls = false }
    }

    private var exposureLabel: String {
        let value = abs(camera.exposureBias) < 0.05 ? 0 : camera.exposureBias
        return String(format: value > 0 ? "+%.1f" : "%.1f", value)
    }

    private func videoControlButton(
        _ control: CameraControl, title: String, symbol: String, value: String
    ) -> some View {
        Button {
            showCameraControls = false
            activeControl = control
        } label: {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .regular))
                    .frame(width: 68, height: 68)
                    .overlay(alignment: .bottomTrailing) {
                        if control == .flash && camera.videoTorchMode == .auto {
                            Text("A")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 14, height: 14)
                                .background(.white, in: Circle())
                                .offset(x: -14, y: -14)
                        }
                    }
                    .background(.black.opacity(0.5), in: Circle())
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .tracking(1.5)
            }
            .rotationEffect(controlLabelAngle)
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private var photoControlsPanelContent: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24), count: 3),
                  alignment: .center, spacing: 24) {
            videoControlButton(.exposure, title: "EXPOSURE", symbol: "plusminus", value: exposureLabel)
                .disabled(!camera.isReady || camera.isBusy || camera.isRecording ||
                          countdownRemaining != nil || !camera.canAdjustExposure)
            Button {
                showCameraControls = false
                activeControl = .grid
            } label: {
                VStack(spacing: 10) {
                    Image(systemName: "square.grid.3x3")
                        .font(.system(size: 26, weight: .light))
                        .frame(width: 68, height: 68)
                        .background(showGrid ? .white.opacity(0.2) : .black.opacity(0.5), in: Circle())
                    Text("GRID")
                        .font(.system(size: 13, weight: .regular))
                        .tracking(1.5)
                }
                .rotationEffect(controlLabelAngle)
                .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("Grid")
            .accessibilityValue(showGrid ? "On" : "Off")

            Button {
                showCameraControls = false
                activeControl = .shutterSound
            } label: {
                VStack(spacing: 10) {
                    Image(systemName: shutterSoundEnabled || !camera.canSuppressShutterSound
                          ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 26, weight: .light))
                        .frame(width: 68, height: 68)
                        .background(shutterSoundEnabled || !camera.canSuppressShutterSound
                                    ? .white.opacity(0.2) : .black.opacity(0.5), in: Circle())
                    Text("SHUTTER SOUND")
                        .font(.system(size: 13, weight: .regular))
                        .tracking(1.5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .rotationEffect(controlLabelAngle)
                .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("Shutter sound")
            .accessibilityValue(camera.canSuppressShutterSound ? (shutterSoundEnabled ? "On" : "Off") : "Unavailable")

            Button {
                showCameraControls = false
                activeControl = .dateTimeStamp
            } label: {
                VStack(spacing: 10) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 26, weight: .light))
                        .frame(width: 68, height: 68)
                        .background(photoDateTimeStampEnabled ? .white.opacity(0.2) : .black.opacity(0.5), in: Circle())
                    Text("DATE & TIME")
                        .font(.system(size: 13, weight: .regular))
                        .tracking(1.5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .rotationEffect(controlLabelAngle)
                .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("Photo date and time stamp")
            .accessibilityValue(photoDateTimeStampEnabled ? "On" : "Off")

            Button {
                showCameraControls = false
                activeControl = .photoQuality
            } label: {
                VStack(spacing: 10) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 26, weight: .light))
                        .frame(width: 68, height: 68)
                        .background(.white.opacity(0.2), in: Circle())
                    Text("PHOTO QUALITY")
                        .font(.system(size: 13, weight: .regular))
                        .tracking(1.5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .rotationEffect(controlLabelAngle)
                .frame(maxWidth: .infinity)
            }
            .disabled(camera.isBusy || camera.isRecording || countdownRemaining != nil)
            .accessibilityLabel("Photo quality")
            .accessibilityValue(photoQuality.title)
        }
    }

    private func controlPanel(for control: CameraControl) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    activeControl = nil
                    showCameraControls = camera.mode == .video || control == .exposure || control == .grid || control == .shutterSound || control == .dateTimeStamp || control == .photoQuality
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 42, height: 42)
                        .background(.black.opacity(0.35), in: Circle())
                }
                .accessibilityLabel("Back")
                Spacer()
                Text(controlTitle(control))
                    .font(.system(size: 16, weight: .medium))
                    .tracking(2)
                Spacer()
                Color.clear.frame(width: 42, height: 42)
            }
            .frame(height: 42)

            Spacer(minLength: 0)
            Text(controlValue(control))
                .font(control == .exposure ? .system(size: 36, weight: .regular, design: .rounded) : .system(size: 36))
                .monospacedDigit()
                .frame(height: 44)

            Spacer(minLength: 0)
            HStack(spacing: 12) {
                switch control {
                case .flash:
                    if camera.mode == .video {
                        videoTorchOption("Auto", symbol: "bolt.fill", mode: .auto)
                        videoTorchOption("On", symbol: "bolt.fill", mode: .on)
                        videoTorchOption("Off", symbol: "bolt.slash.fill", mode: .off)
                    } else {
                        flashOption("Auto", symbol: "bolt.fill", mode: .auto)
                        flashOption("On", symbol: "bolt.fill", mode: .on)
                        flashOption("Off", symbol: "bolt.slash.fill", mode: .off)
                    }
                case .exposure:
                    ExposureRuler(value: Binding(
                        get: { camera.exposureBias },
                        set: { camera.setExposureBias($0) }
                    ), range: camera.exposureRange)
                        .frame(width: 168, height: 40)
                        .disabled(!camera.isReady || camera.isBusy || camera.isRecording ||
                                  countdownRemaining != nil || !camera.canAdjustExposure)
                case .timer:
                    timerOption(0)
                    timerOption(3)
                    timerOption(5)
                    timerOption(10)
                case .grid:
                    settingOption("On", symbol: "square.grid.3x3", selected: showGrid) { showGrid = true }
                    settingOption("Off", symbol: "square.grid.3x3", selected: !showGrid) { showGrid = false }
                case .dateTimeStamp:
                    settingOption("On", symbol: "calendar.badge.clock", selected: photoDateTimeStampEnabled) {
                        photoDateTimeStampEnabled = true
                    }
                    settingOption("Off", symbol: "calendar", selected: !photoDateTimeStampEnabled) {
                        photoDateTimeStampEnabled = false
                    }
                case .photoQuality:
                    settingOption("Quality", symbol: "camera.aperture", selected: photoQuality == .quality) {
                        guard !camera.isBusy, !camera.isRecording, countdownRemaining == nil else { return }
                        photoQuality = .quality
                    }
                    settingOption("Balanced", symbol: "speedometer", selected: photoQuality == .balanced) {
                        guard !camera.isBusy, !camera.isRecording, countdownRemaining == nil else { return }
                        photoQuality = .balanced
                    }
                    settingOption("Speed", symbol: "bolt.fill", selected: photoQuality == .speed) {
                        guard !camera.isBusy, !camera.isRecording, countdownRemaining == nil else { return }
                        photoQuality = .speed
                    }
                case .shutterSound:
                    settingOption("On", symbol: "speaker.wave.2.fill",
                                  selected: camera.canSuppressShutterSound && shutterSoundEnabled) {
                        shutterSoundEnabled = true
                    }
                    settingOption("Off", symbol: "speaker.slash.fill",
                                  selected: camera.canSuppressShutterSound && !shutterSoundEnabled) {
                        shutterSoundEnabled = false
                    }
                }
            }
            .disabled(control == .shutterSound && !camera.canSuppressShutterSound)
            .disabled(control == .photoQuality && (camera.isBusy || camera.isRecording || countdownRemaining != nil))
            .disabled(camera.mode == .video && (!camera.isReady || camera.isBusy || camera.isRecording ||
                      (control == .exposure && !camera.canAdjustExposure)))
            .frame(height: 56)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .frame(height: 190)
        .frame(maxWidth: 500)
        .background(Color(white: 0.13).opacity(0.97), in: RoundedRectangle(cornerRadius: 36))
        .overlay(RoundedRectangle(cornerRadius: 36).strokeBorder(.white.opacity(0.2)))
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
            if value.translation.height > 50,
               value.translation.height > abs(value.translation.width) {
                activeControl = nil
                showCameraControls = false
            }
        })
        .accessibilityAction(.escape) {
            activeControl = nil
            showCameraControls = camera.mode == .video || control == .exposure || control == .grid || control == .shutterSound || control == .dateTimeStamp || control == .photoQuality
        }
    }

    private func controlTitle(_ control: CameraControl) -> String {
        switch control {
        case .flash: "FLASH"
        case .exposure: "EXPOSURE"
        case .timer: "TIMER"
        case .grid: "GRID"
        case .dateTimeStamp: "DATE & TIME"
        case .photoQuality: "PHOTO QUALITY"
        case .shutterSound: "SHUTTER SOUND"
        }
    }

    private func controlValue(_ control: CameraControl) -> String {
        switch control {
        case .flash: camera.mode == .video ? camera.videoTorchDescription : camera.flashDescription
        case .exposure: exposureLabel
        case .timer: timerSeconds == 0 ? "Off" : "\(timerSeconds)s"
        case .grid: showGrid ? "On" : "Off"
        case .dateTimeStamp: photoDateTimeStampEnabled ? "On" : "Off"
        case .photoQuality: photoQuality.title
        case .shutterSound: camera.canSuppressShutterSound ? (shutterSoundEnabled ? "On" : "Off") : "Unavailable"
        }
    }

    private func settingOption(
        _ title: String,
        symbol: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 28))
                    .frame(height: 36)
                Text(title).font(.caption)
            }
            .foregroundStyle(selected ? .yellow : .white)
            .frame(maxWidth: .infinity)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func flashOption(_ title: String, symbol: String, mode: AVCaptureDevice.FlashMode) -> some View {
        Button {
            camera.setFlashMode(mode)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 34))
                    .frame(height: 46)
                    .overlay(alignment: .bottomTrailing) {
                        if mode == .auto {
                            Text("A")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 14, height: 14)
                            .background(camera.flashMode == .auto ? .yellow : .white, in: Circle())
                        }
                    }
            }
            .foregroundStyle(camera.flashMode == mode ? .yellow : .white)
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel("Flash \(title)")
        .accessibilityAddTraits(camera.flashMode == mode ? .isSelected : [])
        .disabled(!camera.supportedFlashModes.contains(mode))
    }

    private func videoTorchOption(_ title: String, symbol: String, mode: AVCaptureDevice.TorchMode) -> some View {
        settingOption(title, symbol: symbol, selected: camera.videoTorchMode == mode) {
            camera.setVideoTorchMode(mode)
        }
        .disabled(!camera.supportedVideoTorchModes.contains(mode))
        .accessibilityLabel("Video flash \(title)")
    }

    private func timerOption(_ seconds: Int) -> some View {
        Button {
            timerSeconds = seconds
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "timer")
                    .font(.system(size: 28))
                    .frame(height: 36)
                Text(seconds == 0 ? "Off" : "\(seconds)s").font(.caption)
            }
            .foregroundStyle(timerSeconds == seconds ? .yellow : .white)
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(seconds == 0 ? "Timer off" : "Timer \(seconds) seconds")
        .accessibilityAddTraits(timerSeconds == seconds ? .isSelected : [])
    }

    private func shutterTapped() {
        if countdownRemaining != nil {
            cancelCountdown()
        } else if camera.isRecording {
            camera.stopRecording()
        } else if camera.mode == .video {
            camera.startRecording()
        } else if timerSeconds > 0 {
            startCountdown()
        } else {
            camera.takePhoto(shutterSoundEnabled: shutterSoundEnabled, dateTimeStampEnabled: photoDateTimeStampEnabled, quality: photoQuality)
        }
    }

    private func startCountdown() {
        guard camera.canAcceptPhoto else { return }
        let delaySeconds = timerSeconds
        let captureQuality = photoQuality
        let id = UUID()
        countdownID = id
        countdownTask = Task { @MainActor in
            for remaining in stride(from: delaySeconds, through: 1, by: -1) {
                guard countdownID == id else { return }
                countdownRemaining = remaining
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    if countdownID == id { cancelCountdown() }
                    return
                }
            }
            guard countdownID == id else { return }
            countdownID = nil
            countdownRemaining = nil
            countdownTask = nil
            guard camera.canAcceptPhoto else {
                camera.errorMessage = "The camera is not ready to take a photo. Please try again."
                return
            }
            camera.takePhoto(shutterSoundEnabled: shutterSoundEnabled, dateTimeStampEnabled: photoDateTimeStampEnabled, quality: captureQuality)
        }
    }

    private func cancelCountdown() {
        countdownID = nil
        countdownTask?.cancel()
        countdownTask = nil
        countdownRemaining = nil
    }

    private func modeButton(_ mode: CameraService.Mode, title: String) -> some View {
        Button { camera.mode = mode } label: {
            Text(title)
                .font(.system(size: 14, weight: camera.mode == mode ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(camera.mode == mode ? .yellow : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(camera.mode == mode ? .white.opacity(0.1) : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(camera.mode == mode ? .white.opacity(0.25) : .clear))
        }
        .disabled(camera.isBusy || camera.isRecording || countdownRemaining != nil)
        .accessibilityAddTraits(camera.mode == mode ? .isSelected : [])
    }
}

private struct ExposureRuler: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    @State private var dragStartValue: Float?
    private let pointsPerEV: CGFloat = 40

    private func setValue(_ proposedValue: Float) {
        let rounded = (proposedValue * 10).rounded() / 10
        value = min(max(rounded, range.lowerBound), range.upperBound)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(-4...4, id: \.self) { index in
                    let tickValue = Float(index) * 0.5
                    if range.contains(tickValue) {
                        Capsule()
                            .fill(.white.opacity(index == 0 ? 0.65 : 0.4))
                            .frame(width: 2, height: 13)
                            .position(x: geometry.size.width / 2 + CGFloat(tickValue - value) * pointsPerEV,
                                      y: geometry.size.height / 2)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .mask(LinearGradient(colors: [.clear, .white, .white, .clear],
                                 startPoint: .leading, endPoint: .trailing))
            .overlay {
                Capsule()
                    .fill(.yellow)
                    .frame(width: 2, height: 26)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { gesture in
                    guard abs(gesture.translation.width) >= abs(gesture.translation.height) else { return }
                    if dragStartValue == nil { dragStartValue = value }
                    guard let dragStartValue else { return }
                    setValue(dragStartValue - Float(gesture.translation.width / pointsPerEV))
                }
                .onEnded { _ in dragStartValue = nil })
            .clipped()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Exposure compensation")
        .accessibilityValue(String(format: "%.1f EV", value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: setValue(value + 0.1)
            case .decrement: setValue(value - 0.1)
            @unknown default: break
            }
        }
        .onDisappear { dragStartValue = nil }
    }
}

private struct CameraGrid: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
                    let x = geometry.size.width * fraction
                    let y = geometry.size.height * fraction
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.4), lineWidth: 0.7)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct LibraryView: View {
    private enum Tab {
        case library
        case collections
        case templates
        case search
    }

    private enum Filter: String, CaseIterable {
        case all = "All Items"
        case photos = "Photos"
        case videos = "Videos"

        func includes(_ item: MediaItem) -> Bool {
            switch self {
            case .all: true
            case .photos: item.kind == .photo
            case .videos: item.kind == .video
            }
        }
    }

    private enum AlbumScope: Equatable {
        case unassigned
        case album(UUID)
    }

    @ObservedObject var store: MediaStore
    let quickAction: CameraQuickActionRequest?
    let close: () -> Void
    @ObservedObject private var searchIndex: PhotoSearchIndex

    init(store: MediaStore, quickAction: CameraQuickActionRequest? = nil, close: @escaping () -> Void) {
        self.store = store
        self.quickAction = quickAction
        self.close = close
        self._searchIndex = ObservedObject(wrappedValue: store.searchIndex)
        let initialTab: Tab = switch quickAction?.action {
        case .collections: .collections
        case .templates: .templates
        default: .library
        }
        self._tab = State(initialValue: initialTab)
        self._hasShownGrid = State(initialValue: initialTab == .library || initialTab == .search)
        self._hasShownCollections = State(initialValue: initialTab == .collections)
    }
    @State private var tab: Tab = .library
    @State private var hasShownGrid = false
    @State private var hasShownCollections = false
    @State private var appliedQuickActionID: UUID?
    @State private var filter: Filter = .all
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var selectionSharePayload: LibrarySharePayload?
    @State private var searchText = ""
    @State private var detailItem: MediaItem?
    @State private var showDeleteConfirmation = false
    @State private var deleteErrorMessage: String?

    @State private var albumScope: AlbumScope?
    @State private var showAlbumNamePrompt = false
    @State private var albumName = ""
    @State private var renamingAlbumID: UUID?
    @State private var albumToDelete: MediaAlbum?
    @State private var showAlbumDeleteConfirmation = false
    @State private var templates: [ReportTemplate] = []
    @State private var templateToEdit: ReportTemplate?
    @State private var templateToDelete: ReportTemplate?
    @State private var showTemplateDeleteConfirmation = false

    private var activeAlbum: MediaAlbum? {
        guard case .album(let id) = albumScope else { return nil }
        return store.albums.first { $0.id == id }
    }

    private var pageTitle: String {
        if tab == .collections { return "Collections" }
        if tab == .templates { return "Templates" }
        if tab == .search { return "Search" }
        if albumScope == .unassigned { return "Not in an Album" }
        return activeAlbum?.name ?? "Library"
    }

    private var scopedItems: [MediaItem] {
        switch albumScope {
        case .unassigned: store.unassignedItems
        case .album: activeAlbum.map { store.items(in: $0) } ?? []
        case nil: store.items
        }
    }

    private var displayedItems: [MediaItem] {
        return scopedItems.filter { item in
            filter.includes(item) &&
            (tab != .search || searchIndex.matches(item, query: searchText))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header(topInset: geometry.safeAreaInsets.top)

                // Retain visited pages and their thumbnail/scroll state across tab changes.
                ZStack(alignment: .top) {
                    if hasShownGrid || tab == .library || tab == .search {
                        VStack(spacing: 0) {
                            if tab == .search {
                                HStack(spacing: 8) {
                                    Image(systemName: "magnifyingglass")
                                    TextField("Search objects, text or filenames", text: $searchText)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                }
                                .padding(12)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                                .padding()
                                searchIndexStatus
                            }
                            grid
                        }
                        .opacity(tab == .library || tab == .search ? 1 : 0)
                        .allowsHitTesting(tab == .library || tab == .search)
                        .accessibilityHidden(tab != .library && tab != .search)
                    }
                    if hasShownCollections || tab == .collections {
                        collections
                            .opacity(tab == .collections ? 1 : 0)
                            .allowsHitTesting(tab == .collections)
                            .accessibilityHidden(tab != .collections)
                    }
                    if tab == .templates {
                        templateList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomBar
            }
            .background(Color(uiColor: .systemBackground))
            .foregroundStyle(.primary)
            .ignoresSafeArea(edges: .top)
            .overlay {
                if showDeleteConfirmation {
                    ZStack(alignment: .bottomTrailing) {
                        Color.black.opacity(0.15)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { showDeleteConfirmation = false }

                        deleteConfirmation
                            .frame(width: min(240, max(0, geometry.size.width - 32)))
                            .padding(.trailing, 16)
                            .padding(.bottom, 8)
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(nil)
        .onAppear {
            applyQuickAction()
        }
        .onChange(of: tab) { _, newTab in
            if newTab == .library || newTab == .search { hasShownGrid = true }
            if newTab == .collections { hasShownCollections = true }
        }
        .onChange(of: quickAction) { _, _ in applyQuickAction() }
        .sheet(item: $selectionSharePayload) { payload in
            LibraryShareSheet(urls: payload.urls)
        }
        .sheet(item: $templateToEdit) { template in
            let isNew = !templates.contains { $0.id == template.id }
            ReportTemplateEditor(template: template, isNew: isNew) { name, content in
                let sourceTemplates = isNew ? templates + [template] : templates
                let updatedTemplates = ReportTemplateStorage.updating(template, name: name, content: content, in: sourceTemplates)
                try ReportTemplateStorage.save(updatedTemplates)
                templates = updatedTemplates
            }
        }
        .fullScreenCover(item: $detailItem) { item in
            NavigationStack {
                MediaDetailView(
                    store: store,
                    item: item,
                    mediaIDs: displayedItems.map(\.id)
                )
            }
            .preferredColorScheme(nil)
        }
        .alert("Error", isPresented: Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Button("OK") { deleteErrorMessage = nil }
        } message: {
            Text(deleteErrorMessage ?? "Unknown error")
        }
        .alert(renamingAlbumID == nil ? "New Album" : "Rename Album", isPresented: $showAlbumNamePrompt) {
            TextField("Album Name", text: $albumName)
            Button("Cancel", role: .cancel) { }
            Button("Save") { saveAlbumName() }
                .disabled(albumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("Delete Album: \(albumToDelete?.name ?? "")?",
                            isPresented: $showAlbumDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Album Only", role: .destructive) { deleteAlbum(includingMedia: false) }
            Button("Delete Album, Photos and Videos", role: .destructive) { deleteAlbum(includingMedia: true) }
            Button("Cancel", role: .cancel) { albumToDelete = nil }
        } message: {
            Text("Deleting only the album keeps its photos and videos. Deleting the album with its photos and videos permanently deletes the original files and related data, and removes them from every album. This cannot be undone.")
        }
        .onChange(of: store.items) { _, _ in
            selectedIDs.formIntersection(Set(displayedItems.map(\.id)))
        }
        .onChange(of: tab) { _, newTab in
            if newTab == .templates { loadTemplates() }
            if newTab == .search { searchIndex.start(items: store.items) }
        }
        .confirmationDialog("Delete Template?", isPresented: $showTemplateDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Template", role: .destructive) {
                guard let templateToDelete else { return }
                do {
                    let remainingTemplates = templates.filter { $0.id != templateToDelete.id }
                    try ReportTemplateStorage.save(remainingTemplates)
                    templates = remainingTemplates
                } catch {
                    deleteErrorMessage = error.localizedDescription
                }
                self.templateToDelete = nil
            }
            Button("Cancel", role: .cancel) { templateToDelete = nil }
        } message: {
            Text("Delete \"\(templateToDelete?.name ?? "")\"? This cannot be undone.")
        }
    }

    private var searchIndexStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if searchIndex.isIndexing {
                ProgressView(value: Double(searchIndex.completedCount + searchIndex.failedCount),
                             total: Double(max(1, searchIndex.totalCount)))
                Text("Analyzing photos: \(searchIndex.completedCount + searchIndex.failedCount)/\(searchIndex.totalCount). Results appear as photos are analyzed.")
            }
            Text("Search photo objects and text in Chinese or English. Object recognition may miss items. Videos are searched by filename.")
            if searchIndex.failedCount > 0 || searchIndex.cacheError != nil {
                HStack {
                    Text(searchIndex.cacheError ?? "\(searchIndex.failedCount) photos could not be fully analyzed.")
                    Spacer()
                    Button("Retry") { searchIndex.retry(items: store.items) }
                        .disabled(searchIndex.isIndexing)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var templateList: some View {
        List {
            if templates.isEmpty {
                Text("No saved templates")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 40)
            } else {
                ForEach(templates) { template in
                    Button { templateToEdit = template } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(template.name).font(.headline)
                            Text(template.content)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit template \(template.name)")
                    .listRowBackground(Color(uiColor: .secondarySystemBackground))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            templateToDelete = template
                            showTemplateDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .accessibilityLabel("Delete template \(template.name)")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func applyQuickAction() {
        guard let request = quickAction, appliedQuickActionID != request.id else { return }
        appliedQuickActionID = request.id
        detailItem = nil
        selectionSharePayload = nil
        templateToEdit = nil
        showDeleteConfirmation = false
        showAlbumNamePrompt = false
        showAlbumDeleteConfirmation = false
        showTemplateDeleteConfirmation = false
        resetSelection()
        albumScope = nil
        filter = .all
        searchText = ""
        switch request.action {
        case .library: tab = .library
        case .collections: tab = .collections
        case .templates:
            tab = .templates
            loadTemplates()
        }
    }

    private func loadTemplates() {
        do {
            templates = try ReportTemplateStorage.load()
        } catch {
            deleteErrorMessage = "Saved report templates could not be read."
        }
    }

    private func header(topInset: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                if albumScope != nil {
                    resetSelection()
                    albumScope = nil
                    tab = .collections
                    filter = .all
                } else { close() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 21))
                    .foregroundStyle(.primary)
                    .frame(width: 52, height: 50)
            }
            .buttonStyle(.plain)
            .frame(width: 50, height: 50)
            .background(Color(uiColor: .secondarySystemBackground), in: Circle())
            .overlay(Circle().strokeBorder(.gray.opacity(0.3)))
            .accessibilityLabel(albumScope == nil ? "Back to Camera" : "Back to Collections")

            VStack(alignment: .leading, spacing: 0) {
                Text(pageTitle)
                    .font(.system(size: 36, weight: .bold))
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
                Text(tab == .templates
                     ? "\(templates.count.formatted()) Templates"
                     : "\((tab == .collections ? store.items.count : displayedItems.count).formatted()) Items")
                    .font(.system(size: 16, weight: .semibold))
            }
            Spacer(minLength: 0)

            if tab == .collections {
                Button { promptForAlbumName() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 23))
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("New Album")
            } else if tab == .templates {
                Button {
                    templateToEdit = ReportTemplate(id: UUID(), name: "", content: "")
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 23))
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("New Template")
            } else {
                Menu {
                    ForEach(Filter.allCases, id: \.self) { option in
                        Button {
                            filter = option
                            selectedIDs.removeAll()
                        } label: {
                            if filter == option {
                                Label(option.rawValue, systemImage: "checkmark")
                            } else {
                                Text(option.rawValue)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 23))
                        .frame(width: 48, height: 48)
                }
                .accessibilityLabel("Filter items")
                .background(.ultraThinMaterial, in: Circle())

                Button {
                    isSelecting.toggle()
                    selectedIDs.removeAll()
                } label: {
                    if isSelecting {
                        Image(systemName: "xmark")
                            .font(.system(size: 23, weight: .regular))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(.gray.opacity(0.3), lineWidth: 1))
                    } else {
                        Text("Select")
                            .font(.system(size: 17))
                            .padding(.horizontal, 18)
                            .frame(height: 48)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelecting ? "Cancel selection" : "Select")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, topInset + 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
        .foregroundStyle(.primary)
    }

    private var grid: some View {
        let items = displayedItems
        return ScrollView {
            if items.isEmpty {
                ContentUnavailableView(
                    albumScope != nil ? "No Items in This Album" : store.items.isEmpty ? "No captures yet" : "No matching items",
                    systemImage: "photo.on.rectangle",
                    description: Text(albumScope != nil
                                      ? "Select photos or videos in Library to add them to an album, or check the current filter."
                                      : store.items.isEmpty ? "Photos and videos you take appear here." : "Try another filter or search.")
                )
                .padding(.top, 60)
            } else {
                // Keep real cells mounted so each visible thumbnail can load independently.
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 5),
                    spacing: 2
                ) {
                    ForEach(items) { item in
                        Button {
                            if isSelecting {
                                if !selectedIDs.insert(item.id).inserted {
                                    selectedIDs.remove(item.id)
                                }
                            } else {
                                detailItem = item
                            }
                        } label: {
                            tile(for: item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.filename)
                        .accessibilityAddTraits(isSelecting && selectedIDs.contains(item.id) ? .isSelected : [])
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .systemBackground))
        .foregroundStyle(.primary)
    }

    private func tile(for item: MediaItem) -> some View {
        GeometryReader { geometry in
            MediaThumbnail(item: item)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if item.kind == .video {
                        VideoDurationBadge(item: item)
                            .padding(.trailing, 4)
                            .padding(.bottom, 4)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if isSelecting {
                        Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(selectedIDs.contains(item.id) ? .blue : .white)
                            .shadow(color: .black.opacity(0.7), radius: 2)
                            .padding(4)
                    }
                }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var collections: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    collectionCard(.photos, symbol: "photo.on.rectangle")
                    collectionCard(.videos, symbol: "video")
                }
                Text("Albums").font(.title2.bold())
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    albumCard(name: "Not in an Album", items: store.unassignedItems,
                              symbol: "tray", scope: .unassigned)
                    ForEach(store.albums) { album in
                        albumCard(name: album.name, items: store.items(in: album),
                                  symbol: "rectangle.stack", scope: .album(album.id))
                            .contextMenu {
                                Button("Rename Album", systemImage: "pencil") { promptForAlbumName(album) }
                                Button("Delete Album", systemImage: "trash", role: .destructive) {
                                    confirmAlbumDeletion(album)
                                }
                            }
                    }
                }
            }
            .padding(16)
        }
        .frame(maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .foregroundStyle(.primary)
    }

    private func collectionCover(items: [MediaItem], symbol: String) -> some View {
        let newestPhoto = items.filter { $0.kind == .photo }.max { $0.createdAt < $1.createdAt }
        let cover = newestPhoto ?? items.max { $0.createdAt < $1.createdAt }
        return GeometryReader { geometry in
            ZStack {
                Color(uiColor: .tertiarySystemFill)
                if let cover {
                    CollectionThumbnail(item: cover, pointSize: geometry.size.width)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 30))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }

    private func albumCard(name: String, items: [MediaItem], symbol: String, scope: AlbumScope) -> some View {
        Button {
            resetSelection()
            albumScope = scope
            filter = .all
            tab = .library
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                collectionCover(items: items, symbol: symbol)
                Text(name).font(.headline).lineLimit(2)
                Text("\(items.count) Items").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func collectionCard(_ collection: Filter, symbol: String) -> some View {
        let items = store.items.filter { collection.includes($0) }
        return Button {
            resetSelection()
            albumScope = nil
            filter = collection
            tab = .library
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                collectionCover(items: items, symbol: symbol)
                Text(collection.rawValue).font(.headline)
                Text("\(items.count) Items")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            if isSelecting {
                HStack(spacing: 0) {
                    Button {
                        shareSelectedItems()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 22, weight: .regular))
                            .frame(width: 48, height: 48)
                            .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                            .overlay(Circle().strokeBorder(.gray.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share selected captures")
                    .disabled(selectedIDs.isEmpty)
                    .opacity(selectedIDs.isEmpty ? 0.4 : 1)
                    Spacer(minLength: 0)
                }
                .frame(width: 96)
                Text("\(selectedIDs.count) Selected")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                Menu {
                    Button("Deselect All") { selectedIDs.removeAll() }
                    ForEach(store.albums) { album in
                        Button("Add to \(album.name)") { updateSelectedAlbum(album.id, adding: true) }
                    }
                    if store.albums.isEmpty {
                        Text("Create an album in Collections first")
                    }
                    if let album = activeAlbum {
                        Button("Remove from This Album") { updateSelectedAlbum(album.id, adding: false) }
                    }
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 22))
                        .frame(width: 48, height: 48)
                }
                .accessibilityLabel("Album Actions")
                .disabled(selectedIDs.isEmpty)
                Button {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)
                        .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                        .overlay(Circle().strokeBorder(.gray.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete selected captures")
                .disabled(selectedIDs.isEmpty)
                .opacity(selectedIDs.isEmpty ? 0.4 : 1)
            } else {
                HStack(spacing: 0) {
                    tabButton(.library, symbol: "photo.on.rectangle.fill", title: "Library")
                    tabButton(.collections, symbol: "square.stack.fill", title: "Collections")
                    tabButton(.templates, symbol: "doc.text", title: "Templates")
                }
                .padding(4)
                .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                .overlay(Capsule().strokeBorder(.gray.opacity(0.3)))
                Spacer(minLength: 8)
                Button {
                    resetSelection()
                    albumScope = nil
                    tab = .search
                    filter = .all
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 27))
                        .frame(width: 52, height: 52)
                        .background(tab == .search ? Color(uiColor: .tertiarySystemFill) : Color(uiColor: .secondarySystemBackground), in: Circle())
                        .overlay(Circle().strokeBorder(.gray.opacity(0.3)))
                }
                .accessibilityLabel("Search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color(uiColor: .systemBackground))
        .foregroundStyle(.primary)
    }

    private func shareSelectedItems() {
        let urls = displayedItems.filter { selectedIDs.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { return }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            deleteErrorMessage = "Some selected files could not be found for sharing."
            return
        }
        selectionSharePayload = LibrarySharePayload(urls: urls)
    }

    private var selectedItemNoun: String {
        let selectedItems = store.items.filter { selectedIDs.contains($0.id) }
        if selectedItems.allSatisfy({ $0.kind == .photo }) {
            return selectedItems.count == 1 ? "Photo" : "Photos"
        } else if selectedItems.allSatisfy({ $0.kind == .video }) {
            return selectedItems.count == 1 ? "Video" : "Videos"
        } else {
            return "Items"
        }
    }

    private var deleteActionTitle: String { "Delete \(selectedItemNoun)" }

    private var albumDeleteQuestion: String {
        let subject = selectedIDs.count == 1
            ? "this \(selectedItemNoun.lowercased())"
            : "these \(selectedIDs.count) \(selectedItemNoun.lowercased())"
        let pronoun = selectedIDs.count == 1 ? "it" : "them"
        return "Do you want to permanently delete \(subject) or remove \(pronoun) from this album?"
    }

    private var deleteConfirmation: some View {
        VStack(alignment: .leading, spacing: 24) {
            if activeAlbum != nil {
                Text(albumDeleteQuestion)
            } else {
                Text(selectedIDs.count == 1
                     ? "This capture and its report will be permanently deleted from this app."
                     : "These \(selectedIDs.count) captures and their reports will be permanently deleted from this app.")
                Text("This action cannot be undone.")
            }

            if let album = activeAlbum {
                Button {
                    showDeleteConfirmation = false
                    updateSelectedAlbum(album.id, adding: false)
                } label: {
                    Text("Remove from Album")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Button(role: .destructive) {
                showDeleteConfirmation = false
                deleteSelectedItems()
            } label: {
                Text(activeAlbum != nil ? "Delete" : deleteActionTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 17))
        .foregroundStyle(.primary)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32))
        .overlay(RoundedRectangle(cornerRadius: 32).strokeBorder(.gray.opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .accessibilityAddTraits(.isModal)
    }

    private func deleteSelectedItems() {
        let selectedItems = store.items.filter { selectedIDs.contains($0.id) }
        for item in selectedItems {
            do {
                try store.delete(item)
                UserDefaults.standard.removeObject(forKey: "favorite.\(item.id).\(item.createdAt.timeIntervalSince1970)")
                selectedIDs.remove(item.id)
            } catch {
                selectedIDs.formIntersection(Set(store.items.map(\.id)))
                deleteErrorMessage = error.localizedDescription
                return
            }
        }
    }

    private func resetSelection() {
        isSelecting = false
        selectedIDs.removeAll()
        showDeleteConfirmation = false
    }

    private func promptForAlbumName(_ album: MediaAlbum? = nil) {
        renamingAlbumID = album?.id
        albumName = album?.name ?? ""
        showAlbumNamePrompt = true
    }

    private func saveAlbumName() {
        do {
            if let id = renamingAlbumID { try store.renameAlbum(id, to: albumName) }
            else { try store.createAlbum(named: albumName) }
        } catch { deleteErrorMessage = error.localizedDescription }
    }

    private func updateSelectedAlbum(_ id: UUID, adding: Bool) {
        do {
            try store.updateAlbum(id, itemIDs: selectedIDs, adding: adding)
            resetSelection()
        } catch { deleteErrorMessage = error.localizedDescription }
    }

    private func confirmAlbumDeletion(_ album: MediaAlbum) {
        albumToDelete = album
        showAlbumDeleteConfirmation = true
    }

    private func deleteAlbum(includingMedia: Bool) {
        guard let album = albumToDelete else { return }
        do {
            try store.deleteAlbum(album.id, includingMedia: includingMedia)
            albumToDelete = nil
        } catch { deleteErrorMessage = error.localizedDescription }
    }

    private func tabButton(_ target: Tab, symbol: String, title: String) -> some View {
        Button {
            resetSelection()
            albumScope = nil
            tab = target
            filter = .all
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 24))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(tab == target ? Color.blue : Color.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(tab == target ? Color(uiColor: .tertiarySystemFill) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct ReportTemplate: Codable, Identifiable {
    let id: UUID
    let name: String
    let content: String
}

private enum ReportTemplateStorage {
    static let key = "reportTemplates.v1"

    static func load() throws -> [ReportTemplate] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([ReportTemplate].self, from: data)
    }

    static func save(_ templates: [ReportTemplate]) throws {
        let data = try JSONEncoder().encode(templates)
        UserDefaults.standard.set(data, forKey: key)
    }

    static func updating(_ template: ReportTemplate, name: String, content: String,
                         in templates: [ReportTemplate]) -> [ReportTemplate] {
        guard let index = templates.firstIndex(where: { $0.id == template.id }) else { return templates }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContent = MediaStore.normalizedReport(content)
        guard !trimmedName.isEmpty,
              !normalizedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return templates }
        var uniqueName = trimmedName
        var suffix = 2
        while templates.contains(where: {
            $0.id != template.id && $0.name.localizedCaseInsensitiveCompare(uniqueName) == .orderedSame
        }) {
            uniqueName = "\(trimmedName) (\(suffix))"
            suffix += 1
        }
        var updatedTemplates = templates
        updatedTemplates[index] = ReportTemplate(id: template.id, name: uniqueName, content: normalizedContent)
        updatedTemplates.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return updatedTemplates
    }
}

private struct ReportTemplateEditor: View {
    let template: ReportTemplate
    let isNew: Bool
    let onSave: (String, String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var content: String
    @State private var saveError: String?

    init(template: ReportTemplate, isNew: Bool = false, onSave: @escaping (String, String) throws -> Void) {
        self.template = template
        self.isNew = isNew
        self.onSave = onSave
        _name = State(initialValue: template.name)
        _content = State(initialValue: template.content)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Template Name").font(.headline)
                TextField("Template Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Text("Content").font(.headline)
                TextEditor(text: $content)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color(uiColor: .separator))
                    }
                    .accessibilityLabel("Template content")
            }
            .padding(20)
            .navigationTitle(isNew ? "New Template" : "Edit Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try onSave(name, content)
                            dismiss()
                        } catch {
                            saveError = error.localizedDescription
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
        .preferredColorScheme(nil)
        .interactiveDismissDisabled(name != template.name || content != template.content)
        .alert("Template could not be saved", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "Unknown error")
        }
    }
}

private struct MediaDetailView: View {
    @ObservedObject var store: MediaStore
    @State private var item: MediaItem
    let mediaIDs: [String]
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var photoImage: UIImage?
    @State private var player: AVPlayer?
    @State private var playbackTime = 0.0
    @State private var playbackDuration = 0.0
    @State private var isPlaying = false
    @State private var isMuted = true
    @State private var isSeeking = false
    @State private var resumeAfterSeeking = false
    @State private var videoControlsVisible = true
    @State private var videoControlsHideAt: Date?
    @State private var report = ""
    @State private var templates: [ReportTemplate] = []
    @State private var templateName = ""
    @State private var pendingTemplate: ReportTemplate?
    @State private var selectedTemplate: ReportTemplate?
    @State private var showTemplates = false
    @State private var showReport = false
    @State private var showInfo = false
    @State private var showPhotoEditor = false
    @State private var showVideoEditor = false
    @State private var photoMetadata: [MetadataEntry] = []
    @State private var metadataReadError: String?
    @State private var photoInfo = PhotoInfoSummary()
    @State private var videoInfo = VideoInfoSummary()
    @State private var videoThumbnail: UIImage?
    @State private var videoCaption = ""
    @State private var videoKeywords = ""
    @State private var savedVideoCaption = ""
    @State private var savedVideoKeywords = ""
    @State private var infoSaveError: String?
    @State private var isLoadingVideoInfo = false
    @State private var locationTitle: String?
    @State private var locationAddress: String?
    @State private var isResolvingAddress = false
    @State private var addressRequest: MKReverseGeocodingRequest?
    @State private var showTemplateNamePrompt = false
    @State private var showReplaceConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var sharePayload: SharePayload?
    @State private var shareSaveError: String?
    @State private var errorMessage: String?

    init(store: MediaStore, item: MediaItem, mediaIDs: [String]) {
        self.store = store
        _item = State(initialValue: item)
        self.mediaIDs = mediaIDs
    }

    private var isDark: Bool { item.kind == .video || colorScheme == .dark }
    private var viewerBackground: Color { isDark ? .black : .white }
    private var controlFill: Color { isDark ? Color(white: 0.14) : .white.opacity(0.88) }
    private var controlSurface: AnyShapeStyle {
        item.kind == .video ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(controlFill)
    }
    private var controlText: Color { isDark ? .white : .black }
    private var controlBorder: Color {
        isDark ? .white.opacity(0.16) : .black.opacity(0.12)
    }
    private var controlShadow: Color { isDark ? .clear : .black.opacity(0.08) }
    private var reportAccent: Color {
        isDark ? Color(red: 0.52, green: 0.73, blue: 1) : .blue
    }

    private var favoriteKey: String {
        "favorite.\(item.id).\(item.createdAt.timeIntervalSince1970)"
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                viewerBackground
                if item.kind == .video {
                    videoViewer(containerSize: geometry.size, landscape: landscape)
                } else if landscape {
                    media
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    VStack(spacing: 0) {
                        topBar(landscape: true, containerSize: geometry.size)
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(spacing: 0) {
                        topBar(landscape: false, containerSize: geometry.size)
                        media
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        bottomBar
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if showDeleteConfirmation {
                    ZStack(alignment: item.kind == .photo && landscape ? .topTrailing : .bottomTrailing) {
                        Color.black.opacity(0.15)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { cancelDeleteConfirmation() }

                        detailDeleteConfirmation
                            .frame(width: min(240, max(0, geometry.size.width - 48)))
                            .padding(.trailing, item.kind == .photo && landscape
                                     ? rightControlInset(in: geometry.size) : 24)
                            .padding(.top, item.kind == .photo && landscape ? 8 : 0)
                            .padding(.bottom, item.kind == .photo && landscape ? 0 : 16)
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(nil)
        .onAppear {
            loadTemplates()
            loadSelection()
            videoControlsVisible = true
            restartVideoControlsTimeout()
        }
        .onDisappear {
            player?.pause()
            videoControlsHideAt = nil
        }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            updatePlaybackState()
            updateVideoControlsVisibility()
        }
        .onChange(of: isSeeking) { _, _ in restartVideoControlsTimeout() }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { notification in
            guard let finishedItem = notification.object as? AVPlayerItem,
                  finishedItem === player?.currentItem else { return }
            isPlaying = false
            playbackTime = playbackDuration
        }
        .sheet(isPresented: $showReport) { reportSheet }
        .sheet(isPresented: $showInfo) { infoSheet }
        .fullScreenCover(isPresented: $showPhotoEditor) {
            if let photoImage {
                PhotoEditorView(image: photoImage, sourceURL: item.url) { data, overwrite in
                    try store.saveEditedPhoto(data, for: item, overwrite: overwrite)
                    if overwrite {
                        self.photoImage = UIImage(contentsOfFile: item.url.path)
                        loadPhotoMetadata()
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showVideoEditor, onDismiss: {
            loadSelection()
        }) {
            VideoEditorView(sourceURL: item.url) { url, overwrite in
                try await store.saveEditedVideo(from: url, for: item, overwrite: overwrite)
                if overwrite {
                    if let updated = store.items.first(where: { $0.id == item.id }) { item = updated }
                    playbackTime = 0
                    playbackDuration = 0
                    await loadVideoInfo()
                }
            }
        }
        .sheet(item: $sharePayload, onDismiss: {
            if let shareSaveError {
                errorMessage = shareSaveError
                self.shareSaveError = nil
            }
        }) { payload in
            ShareSheet(items: payload.items, originalURL: payload.originalURL,
                       originalKind: payload.originalKind, videoLocation: payload.videoLocation) { message in
                shareSaveError = message
            }
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    @ViewBuilder
    private var media: some View {
        if let photoImage, item.kind == .photo {
            ZoomablePhotoSurface(image: photoImage) { direction in
                selectAdjacentMedia(offset: direction == .left ? 1 : -1)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(item.filename)
                .accessibilityAction(named: "Previous Media") { selectAdjacentMedia(offset: -1) }
                .accessibilityAction(named: "Next Media") { selectAdjacentMedia(offset: 1) }
        } else if let player, item.kind == .video {
            VideoPlaybackSurface(player: player) { direction in
                selectAdjacentMedia(offset: direction == .left ? 1 : -1)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(item.filename)
                .accessibilityAction(named: "Previous Media") { selectAdjacentMedia(offset: -1) }
                .accessibilityAction(named: "Next Media") { selectAdjacentMedia(offset: 1) }
        } else {
            ContentUnavailableView("Unable to open media", systemImage: "exclamationmark.triangle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func videoViewer(containerSize: CGSize, landscape: Bool) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            media
                .frame(width: containerSize.width, height: containerSize.height)
                .contentShape(Rectangle())
                .onTapGesture { toggleVideoControls() }
                .accessibilityAction(named: videoControlsVisible ? "Hide controls" : "Show controls") {
                    toggleVideoControls()
                }
            VStack(spacing: 0) {
                // Keep the same three floating controls in both orientations.
                topBar(landscape: false, containerSize: containerSize)
                Spacer(minLength: 12)
                videoPlaybackControls
                    .padding(.horizontal, landscape ? 48 : 24)
                    .padding(.bottom, 8)
                bottomBar
                    .background(.black.opacity(0.65))
            }
            .opacity(videoControlsVisible ? 1 : 0)
            .allowsHitTesting(videoControlsVisible)
            .accessibilityHidden(!videoControlsVisible)
            .simultaneousGesture(TapGesture().onEnded { restartVideoControlsTimeout() })
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func restartVideoControlsTimeout() {
        guard item.kind == .video, videoControlsVisible else { return }
        videoControlsHideAt = Date().addingTimeInterval(3)
    }

    private func toggleVideoControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            videoControlsVisible.toggle()
        }
        if videoControlsVisible {
            restartVideoControlsTimeout()
        } else {
            videoControlsHideAt = nil
        }
    }

    private func updateVideoControlsVisibility() {
        guard item.kind == .video, videoControlsVisible,
              let hideAt = videoControlsHideAt else { return }
        // Keep controls available during seeking and while a presented action is open.
        if isSeeking || showReport || showInfo || sharePayload != nil ||
            showDeleteConfirmation || errorMessage != nil {
            restartVideoControlsTimeout()
            return
        }
        guard Date() >= hideAt else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            videoControlsVisible = false
        }
        videoControlsHideAt = nil
    }

    private var videoPlaybackControls: some View {
        HStack(spacing: 16) {
            Button {
                guard let player else { return }
                restartVideoControlsTimeout()
                if player.rate > 0 {
                    player.pause()
                    isPlaying = false
                } else {
                    if playbackDuration > 0, playbackTime >= playbackDuration - 0.1 {
                        player.seek(to: .zero)
                        playbackTime = 0
                    }
                    player.play()
                    isPlaying = true
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 32, height: 44)
            }
            .accessibilityLabel(isPlaying ? "Pause video" : "Play video")
            .disabled(player == nil || isSeeking)

            Slider(value: $playbackTime, in: 0...max(playbackDuration, 0.01)) { editing in
                guard let player else { return }
                if editing {
                    resumeAfterSeeking = player.rate > 0
                    isSeeking = true
                    player.pause()
                } else {
                    player.seek(to: CMTime(seconds: playbackTime, preferredTimescale: 600),
                                toleranceBefore: .zero, toleranceAfter: .zero)
                    isSeeking = false
                    if resumeAfterSeeking { player.play() }
                    isPlaying = resumeAfterSeeking
                }
            }
            .tint(.white)
            .disabled(playbackDuration <= 0)
            .accessibilityLabel("Video progress")
            .accessibilityValue("\(Int(playbackTime)) of \(Int(playbackDuration)) seconds")

            Button {
                restartVideoControlsTimeout()
                isMuted.toggle()
                player?.isMuted = isMuted
            } label: {
                Image(systemName: isMuted ? "speaker.slash" : "speaker.wave.2")
                    .font(.system(size: 22))
                    .frame(width: 32, height: 44)
            }
            .accessibilityLabel(isMuted ? "Unmute video" : "Mute video")
            .disabled(player == nil)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
    }

    private func updatePlaybackState() {
        guard item.kind == .video, let player else { return }
        let duration = player.currentItem?.duration.seconds ?? 0
        playbackDuration = duration.isFinite && duration > 0 ? duration : 0
        guard !isSeeking else { return }
        let time = player.currentTime().seconds
        playbackTime = time.isFinite ? min(max(0, time), playbackDuration) : 0
        isPlaying = player.rate > 0
    }

    private func topBar(landscape: Bool, containerSize: CGSize) -> some View {
        Group {
            if landscape {
                ZStack {
                    titlePill
                    HStack(spacing: 8) {
                        roundButton("chevron.left", label: "Back to Library") { dismiss() }
                        HStack(spacing: 0) {
                            iconButton("square.and.arrow.up", label: "Share Media", action: share)
                            reportButton
                        }
                        .background(controlSurface, in: Capsule())
                        .overlay(Capsule().strokeBorder(controlBorder))
                        .shadow(color: controlShadow, radius: 10, y: 5)

                        Spacer(minLength: 8)

                        HStack(spacing: 0) {
                            iconButton("info.circle", label: "Info") { showInfo = true }
                            editButton
                            iconButton("trash", label: "Delete capture") { requestDeleteConfirmation() }
                            moreMenu
                        }
                        .background(controlSurface, in: Capsule())
                        .overlay(Capsule().strokeBorder(controlBorder))
                        .shadow(color: controlShadow, radius: 10, y: 5)
                        .padding(.trailing, rightControlInset(in: containerSize) - 24)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    roundButton("chevron.left", label: "Back to Library") { dismiss() }
                    Spacer(minLength: 8)
                    titlePill
                    Spacer(minLength: 8)
                    moreMenu
                        .background(controlSurface, in: Circle())
                        .overlay(Circle().strokeBorder(controlBorder))
                        .shadow(color: controlShadow, radius: 10, y: 5)
                }
            }
        }
        .padding(.horizontal, landscape ? 24 : 16)
        .padding(.top, landscape ? 8 : 14)
        .padding(.bottom, 8)
    }

    private func rightControlInset(in containerSize: CGSize) -> CGFloat {
        guard item.kind == .photo, let photoImage,
              containerSize.width > 0, containerSize.height > 0 else { return 24 }

        let quarterTurn: Bool
        switch photoImage.imageOrientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            quarterTurn = true
        default:
            quarterTurn = false
        }
        let imageWidth = quarterTurn ? photoImage.size.height : photoImage.size.width
        let imageHeight = quarterTurn ? photoImage.size.width : photoImage.size.height
        guard imageWidth > 0, imageHeight > 0 else { return 24 }

        let displayedWidth = min(containerSize.width, containerSize.height * imageWidth / imageHeight)
        let rightGutter = (containerSize.width - displayedWidth) / 2
        let actionWidth: CGFloat = 52 * 3 + 50
        return max(24, (rightGutter - actionWidth) / 2)
    }

    private var titlePill: some View {
        VStack(spacing: 1) {
            Text(item.filename)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 13))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: 220, minHeight: 52)
        .foregroundStyle(controlText)
        .background(controlSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(controlBorder))
        .shadow(color: controlShadow, radius: 10, y: 5)
    }

    private var bottomBar: some View {
        HStack {
            roundButton("square.and.arrow.up", label: "Share Media", action: share)
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                reportButton
                iconButton("info.circle", label: "Info") { showInfo = true }
                editButton
            }
            .background(controlSurface, in: Capsule())
            .overlay(Capsule().strokeBorder(controlBorder))
            .shadow(color: controlShadow, radius: 8, y: 3)
            Spacer(minLength: 4)
            roundButton("trash", label: "Delete capture") { requestDeleteConfirmation() }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private func requestDeleteConfirmation() {
        if item.kind == .video {
            videoControlsVisible = true
            restartVideoControlsTimeout()
        }
        showDeleteConfirmation = true
    }

    private func cancelDeleteConfirmation() {
        showDeleteConfirmation = false
        restartVideoControlsTimeout()
    }

    private var detailDeleteConfirmation: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(item.kind == .photo
                 ? "This capture and its report will be permanently deleted from this app."
                 : "This video and its report will be permanently deleted from this app.")
            Text("This action cannot be undone.")

            Button(role: .destructive) {
                showDeleteConfirmation = false
                deleteCurrentItem()
            } label: {
                Text(item.kind == .photo ? "Delete Photo" : "Delete Video")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.38, blue: 0.4))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 17))
        .foregroundStyle(.white)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32))
        .overlay(RoundedRectangle(cornerRadius: 32).strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { cancelDeleteConfirmation() }
        .environment(\.colorScheme, .dark)
    }

    private func deleteCurrentItem() {
        do {
            let oldKey = favoriteKey
            try store.delete(item)
            UserDefaults.standard.removeObject(forKey: oldKey)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private var editButton: some View {
        iconButton("slider.horizontal.3", label: item.kind == .photo ? "Edit Photo" : "Edit Video", action: openEditor)
            .disabled(item.kind == .photo && photoImage == nil)
    }

    private func openEditor() {
        if item.kind == .photo {
            showPhotoEditor = true
        } else {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            isPlaying = false
            showVideoEditor = true
        }
    }

    private var reportButton: some View {
        let hasReport = !report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return Button {
            restartVideoControlsTimeout()
            showReport = true
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 21))
                .foregroundStyle(hasReport ? reportAccent : controlText)
                .frame(width: 52, height: 50)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Report")
        .accessibilityValue(hasReport ? "Report added" : "No report")
    }

    private var moreMenu: some View {
        Menu {
            Button("Report") { showReport = true }
            Button("Info") { showInfo = true }
            Button(item.kind == .photo ? "Edit Photo" : "Edit Video", action: openEditor)
                .disabled(item.kind == .photo && photoImage == nil)
            Button("Share Media", action: share)
            Button("Delete capture", role: .destructive) { requestDeleteConfirmation() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(controlText)
                .frame(width: 50, height: 50)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More actions")
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            restartVideoControlsTimeout()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 21))
                .foregroundStyle(controlText)
                .frame(width: 52, height: 50)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        iconButton(symbol, label: label, action: action)
            .frame(width: 50, height: 50)
            .background(controlSurface, in: Circle())
            .overlay(Circle().strokeBorder(controlBorder))
            .shadow(color: controlShadow, radius: 10, y: 5)
    }

    private var reportSheet: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemBackground).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Button("Cancel") {
                            report = store.report(for: item)
                            showTemplateNamePrompt = false
                            showReport = false
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color(uiColor: .separator)))
                        Spacer()
                        Button("Save") {
                            if saveReport() {
                                showTemplateNamePrompt = false
                                showReport = false
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .background(.blue, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .overlay {
                        Text("Report")
                            .font(.headline)
                            .foregroundStyle(Color.primary)
                            .allowsHitTesting(false)
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Capture Report")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(Color.primary)
                            Text(item.filename)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            showTemplates = true
                        } label: {
                            Label("Templates", systemImage: "doc.text")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.blue)
                                .padding(.horizontal, 14)
                                .frame(height: 40)
                                .background(Color.blue.opacity(0.09), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showTemplates) {
                            templatePicker
                                .presentationCompactAdaptation(.popover)
                                .onDisappear {
                                    if let template = selectedTemplate {
                                        selectedTemplate = nil
                                        chooseTemplate(template)
                                    }
                                }
                        }
                    }
                    TextEditor(text: $report)
                        .scrollContentBackground(.hidden)
                        .foregroundColor(Color.primary)
                        .padding(12)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(Color(uiColor: .separator))
                        }
                        .shadow(color: Color.black.opacity(0.08), radius: 12, y: 5)
                        .accessibilityLabel("Report")
                    if showTemplateNamePrompt {
                        TextField("Template Name", text: $templateName)
                            .foregroundStyle(Color.primary)
                            .padding(12)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.blue.opacity(0.5))
                            }
                        HStack {
                            Button("Cancel") { showTemplateNamePrompt = false }
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.primary)
                                .padding(.horizontal, 16)
                                .frame(height: 42)
                                .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color(uiColor: .separator)))
                            Spacer()
                            Button("Save Template") {
                                saveTemplate()
                                showTemplateNamePrompt = false
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 42)
                            .background(.blue, in: Capsule())
                            .disabled(templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .opacity(templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                        }
                        .buttonStyle(.plain)
                    } else {
                        HStack {
                            Button("Save as Template") {
                                templateName = ""
                                showTemplateNamePrompt = true
                            }
                            .disabled(report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.blue)
                            .padding(.horizontal, 14)
                            .frame(height: 42)
                            .background(Color.blue.opacity(0.09), in: Capsule())
                            .opacity(report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                            Spacer()
                            Button {
                                report = ""
                            } label: {
                                Label("Clear", systemImage: "xmark.circle")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.blue)
                                    .padding(.horizontal, 14)
                                    .frame(height: 42)
                                    .background(Color.blue.opacity(0.09), in: Capsule())
                            }
                            .disabled(report.isEmpty)
                            .opacity(report.isEmpty ? 0.45 : 1)
                            .accessibilityLabel("Clear report text")
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Share automatically includes the Report with the media.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(nil)
        .interactiveDismissDisabled(report != store.report(for: item))
        .confirmationDialog("Replace the current report text?", isPresented: $showReplaceConfirmation) {
            Button("Replace Report") {
                if let pendingTemplate { report = pendingTemplate.content }
                pendingTemplate = nil
            }
            Button("Cancel", role: .cancel) { pendingTemplate = nil }
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var templatePicker: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if templates.isEmpty {
                    Text("No saved templates")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 16)
                } else {
                    ForEach(templates) { template in
                        Button {
                            selectedTemplate = template
                            showTemplates = false
                        } label: {
                            Text(template.name)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                        }
                        .foregroundStyle(Color.primary)
                        Divider()
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 320, height: min(CGFloat(max(templates.count, 1)) * 52 + 16, 320))
        .background(Color(uiColor: .secondarySystemBackground))
        .preferredColorScheme(nil)
    }

    private var infoCardColor: Color { Color(uiColor: .secondarySystemBackground) }
    private var infoBadgeColor: Color { Color(uiColor: .tertiarySystemFill) }

    private var infoSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if item.kind == .video {
                        videoAnnotationCard(title: "Caption", placeholder: "Add a Caption", text: $videoCaption)
                        if isLoadingVideoInfo { ProgressView("Reading Video Info…") }
                    }
                    infoSummaryCard
                    if let coordinate = infoCoordinate {
                        infoLocationCard(coordinate)
                    } else if item.kind == .video {
                        Label("Capture Location: Not provided", systemImage: "mappin.slash")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(infoCardColor, in: RoundedRectangle(cornerRadius: 26))
                    }
                    if item.kind == .video {
                        videoAnnotationCard(title: "Keywords", placeholder: "Add Keywords", text: $videoKeywords)
                    }
                    DisclosureGroup("Complete Metadata") {
                        VStack(alignment: .leading, spacing: 14) {
                            if item.kind == .video,
                               videoInfo.lensAtRecordingStart || videoInfo.focalLength.contains("(nominal)") {
                                Text(videoCaptureNote)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let metadataReadError {
                                Text(metadataReadError).foregroundStyle(.secondary)
                            }
                            if photoMetadata.isEmpty, metadataReadError == nil {
                                Text("No readable metadata found.").foregroundStyle(.secondary)
                            }
                            ForEach(photoMetadata) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.id).font(.caption).foregroundStyle(.secondary)
                                    Text(entry.value).textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 14)
                    }
                    .font(.subheadline)
                    .padding(16)
                    .background(infoCardColor, in: RoundedRectangle(cornerRadius: 26))
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(item.kind == .video && videoAnnotationsChanged ? "Save" : "Done") {
                        if item.kind == .photo || saveVideoAnnotations() { showInfo = false }
                    }
                }
            }
            .task(id: item.url) {
                if item.kind == .video {
                    await loadVideoInfo()
                } else {
                    loadPhotoMetadata()
                }
                await loadCaptureAddress()
            }
            .interactiveDismissDisabled(item.kind == .video && videoAnnotationsChanged)
            .alert("Could Not Save Info", isPresented: Binding(
                get: { infoSaveError != nil },
                set: { if !$0 { infoSaveError = nil } }
            )) {
                Button("OK") { infoSaveError = nil }
            } message: {
                Text(infoSaveError ?? "Unknown error")
            }
            .onDisappear { addressRequest?.cancel() }
        }
        .preferredColorScheme(nil)
        .tint(.blue)
    }

    private var infoSummaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.kind == .photo ? photoInfo.captured : videoInfo.captured)
                    .font(.subheadline)
                Text(item.filename).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            HStack(alignment: .center, spacing: 8) {
                Text(item.kind == .photo ? photoInfo.device : videoInfo.device)
                    .font(.subheadline)
                Spacer(minLength: 8)
                Text(item.kind == .photo ? photoInfo.format : videoInfo.format)
                    .font(.subheadline)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(infoBadgeColor, in: Capsule())
                if item.kind == .video {
                    Image(systemName: "video")
                        .font(.subheadline)
                        .padding(.horizontal, 5).padding(.vertical, 4)
                        .background(infoBadgeColor, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            if item.kind == .photo {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(photoInfo.lens) — \(photoInfo.lensFocalLength) ƒ\(photoInfo.aperture)")
                            .font(.subheadline)
                        Text("\(photoInfo.resolution) • \(photoInfo.fileSize)")
                            .font(.subheadline)
                    }
                    Spacer(minLength: 8)
                    Text("STANDARD")
                        .font(.subheadline)
                        .fixedSize()
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(infoBadgeColor, in: Capsule())
                }
                .foregroundStyle(.secondary)
                .padding(16)
                Divider()
                HStack(spacing: 0) {
                    infoExposureValue("ISO \(photoInfo.iso)")
                    Divider()
                    infoExposureValue(photoInfo.focalLength)
                    Divider()
                    infoExposureValue("\(photoInfo.exposureBias) ev")
                    Divider()
                    infoExposureValue("ƒ\(photoInfo.aperture)")
                    Divider()
                    infoExposureValue(photoInfo.shutter)
                }
                .frame(height: 24)
                .padding(.vertical, 16)
                .padding(.horizontal, 6)
            } else {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(videoLensSummary)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            Text("\(videoInfo.resolution) • \(videoInfo.fileSize) •")
                            Label(videoInfo.dynamicRange, systemImage: "tv")
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(videoInfo.resolution) • \(videoInfo.fileSize)")
                            Label(videoInfo.dynamicRange, systemImage: "tv")
                        }
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(16)
                Divider()
                HStack(spacing: 0) {
                    Text(videoInfo.frameRate).frame(maxWidth: .infinity)
                    Divider()
                    Text(videoInfo.duration).frame(maxWidth: .infinity)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(height: 20)
                .padding(.vertical, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(infoCardColor, in: RoundedRectangle(cornerRadius: 26))
    }

    private var videoLensSummary: String {
        let focalLength = videoInfo.focalLength.replacingOccurrences(of: " (nominal)", with: "")
        let aperture = videoInfo.aperture == "Not provided" ? "Aperture: Not provided" : "f\(videoInfo.aperture)"
        return "\(videoInfo.lens) - \(focalLength) \(aperture)"
    }

    private var videoCaptureNote: String {
        var notes: [String] = []
        if videoInfo.lensAtRecordingStart { notes.append("Lens and aperture at recording start") }
        if videoInfo.focalLength.contains("(nominal)") { notes.append("Nominal focal length") }
        return notes.joined(separator: " • ")
    }

    private func infoExposureValue(_ value: String) -> some View {
        Text(value)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(value)
    }

    private func infoLocationCard(_ coordinate: CLLocationCoordinate2D) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Map(initialPosition: .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
            )), interactionModes: []) {
                Annotation("Capture Location", coordinate: coordinate) {
                    Group {
                        if let image = item.kind == .photo ? photoImage : videoThumbnail {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Image(systemName: item.kind == .photo ? "photo.fill" : "video.fill")
                        }
                    }
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(3)
                    .background(.white, in: RoundedRectangle(cornerRadius: 11))
                    .shadow(radius: 4)
                }
                .annotationTitles(.hidden)
            }
            .frame(height: 170)
            VStack(alignment: .leading, spacing: 5) {
                Text(locationTitle ?? (isResolvingAddress ? "Finding Address…" : "Capture Location"))
                    .font(.subheadline)
                    .foregroundStyle(.blue)
                Text(locationAddress ?? String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(infoCardColor)
        .clipShape(RoundedRectangle(cornerRadius: 26))
    }

    private var infoCoordinate: CLLocationCoordinate2D? {
        item.kind == .photo ? photoInfo.coordinate : videoInfo.coordinate
    }

    private var videoAnnotationsChanged: Bool {
        videoCaption != savedVideoCaption || videoKeywords != savedVideoKeywords
    }

    private func videoAnnotationCard(title: String, placeholder: String, text: Binding<String>) -> some View {
        TextField(title, text: text, prompt: Text(placeholder)
            .foregroundStyle(title == "Keywords" ? Color.blue : Color(uiColor: .placeholderText)), axis: .vertical)
        .font(.subheadline)
        .lineLimit(1...6)
        .disabled(isLoadingVideoInfo)
        .accessibilityLabel(title)
        .accessibilityHint(title == "Keywords" ? "Separate keywords with commas" : "")
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(infoCardColor, in: RoundedRectangle(cornerRadius: 26))
    }

    private func keywordList(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: CharacterSet(charactersIn: ",，;；\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    @discardableResult
    private func saveVideoAnnotations() -> Bool {
        // Done may be tapped while the asynchronous metadata read is still in flight.
        guard !isLoadingVideoInfo else { return !videoAnnotationsChanged }
        do {
            if videoCaption != savedVideoCaption {
                try store.saveReport(videoCaption, for: item)
                report = videoCaption
                savedVideoCaption = videoCaption
            }
            if videoKeywords != savedVideoKeywords {
                let keywords = keywordList(videoKeywords)
                try store.saveKeywords(keywords, for: item)
                videoKeywords = keywords.joined(separator: ", ")
                savedVideoKeywords = videoKeywords
            }
            return true
        } catch {
            infoSaveError = error.localizedDescription
            return false
        }
    }

    private struct VideoInfoSummary {
        var captured = "Not provided"
        var device = "Not provided"
        var format = "Not provided"
        var lens = "Not provided"
        var focalLength = "Not provided"
        var aperture = "Not provided"
        var resolution = "Not provided"
        var fileSize = "Not provided"
        var dynamicRange = "HDR: Not provided"
        var frameRate = "FPS: Not provided"
        var duration = "Duration: Not provided"
        var coordinate: CLLocationCoordinate2D?
        var lensAtRecordingStart = false
        var locationName: String?
    }

    private func videoDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMM yyyy HH:mm")
        return formatter.string(from: date)
    }

    private func positiveMetadataNumber(_ text: String?) -> Double? {
        guard let text,
              let range = text.range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression),
              let value = Double(text[range]), value.isFinite, value > 0 else { return nil }
        return value
    }

    private func videoDecimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func videoCoordinate(_ value: String?) -> CLLocationCoordinate2D? {
        // QuickTime uses signed ISO 6709 latitude/longitude, optionally followed by altitude.
        guard let value,
              let expression = try? NSRegularExpression(
                pattern: #"^([+-][0-9]{2}(?:\.[0-9]+)?)([+-][0-9]{3}(?:\.[0-9]+)?)(?:[+-][0-9]+(?:\.[0-9]+)?)?/$"#
              ),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let latitudeRange = Range(match.range(at: 1), in: value),
              let longitudeRange = Range(match.range(at: 2), in: value),
              let latitude = Double(value[latitudeRange]),
              let longitude = Double(value[longitudeRange]) else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    private func loadVideoInfo() async {
        let sourceURL = item.url
        isLoadingVideoInfo = true
        defer { isLoadingVideoInfo = false }
        videoThumbnail = nil
        infoSaveError = nil
        photoMetadata = []
        metadataReadError = nil
        videoCaption = store.report(for: item)
        videoKeywords = store.keywords(for: item).joined(separator: ", ")
        savedVideoCaption = videoCaption
        savedVideoKeywords = videoKeywords
        var summary = VideoInfoSummary()
        let details = store.videoCaptureDetails(for: item)
        if let details {
            summary.captured = videoDate(details.capturedAt)
            summary.device = VideoCaptureDetails.deviceDisplayName(details.device)
            summary.lens = details.lens ?? "Not provided"
            if let value = details.focalLength35mm, value.isFinite, value > 0 {
                summary.focalLength = "\(videoDecimal(value)) mm (nominal)"
            }
            if let value = details.aperture, value.isFinite, value > 0 {
                summary.aperture = videoDecimal(value)
            }
            summary.lensAtRecordingStart = details.lens != nil || details.aperture != nil
            if let latitude = details.latitude, let longitude = details.longitude {
                let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                if CLLocationCoordinate2DIsValid(coordinate) { summary.coordinate = coordinate }
            }
        } else if item.createdAt != .distantPast {
            summary.captured = "File date: \(videoDate(item.createdAt))"
        }
        if let size = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            summary.fileSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        videoInfo = summary
        let asset = AVURLAsset(url: sourceURL)
        var readErrors: [String] = []
        var values: [AVMetadataIdentifier: String] = [:]
        var entries: [MetadataEntry] = []
        func collect(_ metadata: [AVMetadataItem], prefix: String) async {
            for (index, entry) in metadata.enumerated() {
                guard !Task.isCancelled else { return }
                let string = try? await entry.load(.stringValue)
                let number = string == nil ? try? await entry.load(.numberValue) : nil
                guard let value = string ?? number?.stringValue, !value.isEmpty else { continue }
                if let identifier = entry.identifier, values[identifier] == nil { values[identifier] = value }
                let key = entry.identifier?.rawValue ?? "Entry \(index + 1)"
                entries.append(MetadataEntry(id: "\(prefix).\(key).\(index)", value: value))
            }
        }
        do {
            let metadata = try await asset.load(.metadata)
            await collect(metadata, prefix: "File")
        } catch { readErrors.append("File metadata could not be read.") }
        do {
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                if let metadata = try? await track.load(.metadata) {
                    await collect(metadata, prefix: "Video track")
                }
                if let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                    let bounds = CGRect(origin: .zero, size: size).applying(transform)
                    let width = abs(bounds.width).rounded(), height = abs(bounds.height).rounded()
                    if width.isFinite, height.isFinite, width > 0, height > 0 {
                        let longEdge = max(width, height), shortEdge = min(width, height)
                        let label = longEdge >= 7680 && shortEdge >= 4320 ? "8K" :
                            longEdge >= 3840 && shortEdge >= 2160 ? "4K" :
                            longEdge >= 1920 && shortEdge >= 1080 ? "HD 1080p" :
                            longEdge >= 1280 && shortEdge >= 720 ? "HD 720p" : "Video"
                        summary.resolution = "\(label) • \(Int(width)) × \(Int(height))"
                    }
                }
                if let rate = try? await track.load(.nominalFrameRate), rate.isFinite, rate > 0 {
                    summary.frameRate = "\(videoDecimal(Double(rate))) FPS"
                }
                if let descriptions = try? await track.load(.formatDescriptions), !descriptions.isEmpty {
                    var codecs = Set<String>(), ranges = Set<String>()
                    for description in descriptions {
                        let codec = CMFormatDescriptionGetMediaSubType(description)
                        switch codec {
                        case kCMVideoCodecType_HEVC, kCMVideoCodecType_DolbyVisionHEVC: codecs.insert("HEVC")
                        case kCMVideoCodecType_H264: codecs.insert("H.264")
                        default:
                            let bytes = [24, 16, 8, 0].map { UInt8((codec >> $0) & 0xff) }
                            codecs.insert(String(bytes: bytes, encoding: .ascii) ?? "Unknown codec")
                        }
                        let extensions = (CMFormatDescriptionGetExtensions(description) as NSDictionary?) ?? NSDictionary()
                        let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? NSDictionary
                        let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String
                        let dolby = codec == kCMVideoCodecType_DolbyVisionHEVC ||
                            atoms?["dvcC"] != nil || atoms?["dvvC"] != nil
                        if dolby { ranges.insert("Dolby Vision") }
                        else if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
                            ranges.insert("HDR (HLG)")
                        } else if transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
                            ranges.insert("HDR (PQ)")
                        } else if let transfer,
                                  [kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
                                   kCMFormatDescriptionTransferFunction_ITU_R_2020 as String,
                                   kCMFormatDescriptionTransferFunction_sRGB as String].contains(transfer) {
                            ranges.insert("SDR")
                        } else { ranges.insert("HDR: Not provided") }
                    }
                    summary.format = codecs.sorted().joined(separator: " / ")
                    summary.dynamicRange = ranges.sorted().joined(separator: " / ")
                }
            } else { readErrors.append("No video track was found.") }
        } catch { readErrors.append("Video track information could not be read.") }
        if let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds >= 0 {
            let seconds = Int(duration.seconds.rounded(.down))
            summary.duration = seconds >= 3600 ?
                String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) :
                String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
        if let rawDate = values[.quickTimeMetadataCreationDate] ?? values[.commonIdentifierCreationDate] {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var date = parser.date(from: rawDate)
            if date == nil {
                parser.formatOptions = [.withInternetDateTime]
                date = parser.date(from: rawDate)
            }
            if let date { summary.captured = videoDate(date) }
        }
        if let model = values[.quickTimeMetadataModel] {
            let make = values[.quickTimeMetadataMake] ?? ""
            let device = make.isEmpty || model.lowercased().hasPrefix(make.lowercased()) ? model : "\(make) \(model)"
            summary.device = VideoCaptureDetails.deviceDisplayName(device)
        }
        if let lens = values[.quickTimeMetadataCameraLensModel] {
            summary.lens = cameraDisplayName(lensModel: lens, make: values[.quickTimeMetadataMake] ?? "",
                                           model: values[.quickTimeMetadataModel] ?? "")
            // Do not combine a file's lens identity with a sidecar's starting-lens aperture.
            summary.lensAtRecordingStart = false
            summary.aperture = "Not provided"
            summary.focalLength = "Not provided"
        }
        if let value = positiveMetadataNumber(values[.quickTimeMetadataCameraLensIrisFNumber]) {
            summary.aperture = videoDecimal(value)
        }
        if let value = positiveMetadataNumber(values[.quickTimeMetadataCameraFocalLength35mmEquivalent]) {
            summary.focalLength = "\(videoDecimal(value)) mm"
        }
        summary.coordinate = videoCoordinate(values[.quickTimeMetadataLocationISO6709]) ?? summary.coordinate
        summary.locationName = values[.quickTimeMetadataLocationName]
        guard !Task.isCancelled, item.url == sourceURL else { return }
        let reportURL = sourceURL.deletingPathExtension().appendingPathExtension("TXT")
        if !FileManager.default.fileExists(atPath: reportURL.path),
           let caption = values[.quickTimeMetadataDescription] ?? values[.commonIdentifierDescription] {
            videoCaption = caption
            savedVideoCaption = caption
        }
        if !store.hasSavedKeywords(for: item), let keywords = values[.quickTimeMetadataKeywords] {
            videoKeywords = keywordList(keywords).joined(separator: ", ")
            savedVideoKeywords = videoKeywords
        }
        videoInfo = summary
        photoMetadata = entries
        // Retain the fields that loaded successfully even if other reads failed.
        metadataReadError = readErrors.isEmpty ? nil : readErrors.joined(separator: " ")
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        if let (image, _) = try? await generator.image(at: .zero), !Task.isCancelled, item.url == sourceURL {
            videoThumbnail = UIImage(cgImage: image)
        }
    }

    private struct PhotoInfoSummary {
        var captured = "—"
        var device = "—"
        var format = "HEIF"
        var lens = "—"
        var resolution = "—"
        var fileSize = "—"
        var iso = "—"
        var focalLength = "—"
        var lensFocalLength = "—"
        var exposureBias = "—"
        var aperture = "—"
        var shutter = "—"
        var coordinate: CLLocationCoordinate2D?
    }

    private func loadCaptureAddress() async {
        addressRequest?.cancel()
        addressRequest = nil
        locationTitle = item.kind == .video ? videoInfo.locationName : nil
        locationAddress = nil
        isResolvingAddress = false
        guard !Task.isCancelled, let coordinate = infoCoordinate,
              let request = MKReverseGeocodingRequest(location: CLLocation(
                latitude: coordinate.latitude, longitude: coordinate.longitude
              )) else { return }
        request.preferredLocale = .current
        addressRequest = request
        isResolvingAddress = true
        defer {
            if addressRequest === request {
                addressRequest = nil
                isResolvingAddress = false
            }
        }
        do {
            let mapItems = try await request.mapItems
            guard !Task.isCancelled, !request.isCancelled, addressRequest === request,
                  let mapItem = mapItems.first else { return }
            func nonempty(_ value: String?) -> String? {
                guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !trimmed.isEmpty else { return nil }
                return trimmed
            }
            let representations = mapItem.addressRepresentations
            locationTitle = (item.kind == .video ? nonempty(videoInfo.locationName) ?? nonempty(mapItem.name) : nil)
                ?? nonempty(representations?.cityWithContext(.automatic))
                ?? nonempty(representations?.regionName)
                ?? nonempty(mapItem.address?.shortAddress)
            locationAddress = nonempty(representations?.fullAddress(includingRegion: true, singleLine: true))
                ?? nonempty(mapItem.address?.fullAddress)
        } catch {
            // Offline, unavailable, or cancelled lookups leave the saved coordinates visible.
        }
    }

    private struct MetadataEntry: Identifiable {
        let id: String
        let value: String
    }

    private func loadPhotoMetadata() {
        photoMetadata = []
        metadataReadError = nil
        photoInfo = PhotoInfoSummary()
        guard item.kind == .photo else { return }
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            metadataReadError = "The saved photo's metadata could not be read."
            return
        }
        photoMetadata = metadataEntries(properties, path: "")
        photoInfo = photoSummary(properties)
    }

    private func photoSummary(_ properties: [String: Any]) -> PhotoInfoSummary {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        var summary = PhotoInfoSummary()
        func number(_ dictionary: [String: Any], _ key: CFString) -> Double? {
            guard let value = (dictionary[key as String] as? NSNumber)?.doubleValue,
                  value.isFinite else { return nil }
            return value
        }
        func decimal(_ value: Double) -> String {
            value.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
        }
        if let original = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            // Display the EXIF wall-clock time without assuming a missing time zone.
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let date = formatter.date(from: original) {
                formatter.dateFormat = "EEEE • d MMM yyyy • HH:mm"
                summary.captured = formatter.string(from: date)
            } else {
                summary.captured = original
            }
        }
        let make = (tiff[kCGImagePropertyTIFFMake as String] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (tiff[kCGImagePropertyTIFFModel as String] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let device = model.hasPrefix(make) ? model : [make, model].filter { !$0.isEmpty }.joined(separator: " ")
        if !device.isEmpty { summary.device = device }
        if let lens = exif[kCGImagePropertyExifLensModel as String] as? String, !lens.isEmpty {
            summary.lens = cameraDisplayName(lensModel: lens, make: make, model: model)
        }
        if let width = number(properties, kCGImagePropertyPixelWidth),
           let height = number(properties, kCGImagePropertyPixelHeight), width > 0, height > 0 {
            summary.resolution = "\(decimal((width * height / 1_000_000).rounded(.down))) MP • \(decimal(width)) × \(decimal(height))"
        }
        if let size = try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            summary.fileSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        if let values = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber],
           let iso = values.first, iso.doubleValue.isFinite, iso.doubleValue > 0 {
            summary.iso = decimal(iso.doubleValue)
        }
        // Match Photos' display using the 35 mm equivalent when the file provides it.
        let equivalent = number(exif, kCGImagePropertyExifFocalLenIn35mmFilm)
        if let focal = equivalent.flatMap({ $0 > 0 ? $0 : nil }) ?? number(exif, kCGImagePropertyExifFocalLength), focal > 0 {
            summary.focalLength = "\(decimal(focal)) mm"
        }
        if let bias = number(exif, kCGImagePropertyExifExposureBiasValue) { summary.exposureBias = decimal(bias) }
        if let aperture = number(exif, kCGImagePropertyExifFNumber), aperture > 0 { summary.aperture = decimal(aperture) }
        summary.lensFocalLength = summary.focalLength
        if let exposure = number(exif, kCGImagePropertyExifExposureTime), exposure > 0 {
            summary.shutter = exposure < 1 ? "1/\(decimal((1 / exposure).rounded())) s" : "\(decimal(exposure)) s"
        }
        if let latitude = number(gps, kCGImagePropertyGPSLatitude), (0...90).contains(latitude),
           let longitude = number(gps, kCGImagePropertyGPSLongitude), (0...180).contains(longitude),
           let latRef = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String)?.uppercased(),
           let lonRef = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String)?.uppercased(),
           ["N", "S"].contains(latRef), ["E", "W"].contains(lonRef) {
            summary.coordinate = CLLocationCoordinate2D(
                latitude: latRef == "S" ? -latitude : latitude,
                longitude: lonRef == "W" ? -longitude : longitude
            )
        }
        return summary
    }

    private func cameraDisplayName(lensModel: String, make: String, model: String) -> String {
        let lens = lensModel.lowercased()
        if lens.contains("back triple camera") { return "Triple Camera" }
        if lens.contains("back ultra wide camera") { return "Ultra Wide Camera" }
        if lens.contains("back telephoto camera") { return "Telephoto Camera" }

        // The device model is already displayed separately in Info.
        // Keep the camera description for lens combinations not yet recognized.
        var displayName = lensModel
        if lens.hasPrefix("iphone "),
           let cameraRange = lens.range(of: " back ") ?? lens.range(of: " front ") {
            let prefixLength = lens.distance(from: lens.startIndex, to: cameraRange.lowerBound) + 1
            displayName = String(lensModel.dropFirst(prefixLength))
        }

        // Match confirmed focal length/aperture combinations independently of model.
        let camera = displayName.lowercased()
        if camera.hasPrefix("back camera ") {
            let values = String(camera.dropFirst("back camera ".count))
                .components(separatedBy: "mm f/")
            if values.count == 2,
               let focalLength = Double(values[0]), let aperture = Double(values[1]),
               focalLength.isFinite, aperture.isFinite {
                if abs(focalLength - 2.22) < 0.01, abs(aperture - 2.2) < 0.01 {
                    return "Ultra Wide Camera"
                }
                if (abs(focalLength - 6.765) < 0.01 && abs(aperture - 1.78) < 0.01)
                    || (abs(focalLength - 6.93) < 0.01 && abs(aperture - 1.48) < 0.01) {
                    return "Main Camera"
                }
                if abs(focalLength - 16.891) < 0.01, abs(aperture - 2.8) < 0.01 {
                    return "Telephoto Camera"
                }
            }
        }
        return displayName
    }

    private func metadataEntries(_ value: Any, path: String) -> [MetadataEntry] {
        if let dictionary = value as? [String: Any] {
            if dictionary.isEmpty { return [MetadataEntry(id: path, value: "{}")] }
            return dictionary.keys.sorted().flatMap { key in
                metadataEntries(dictionary[key]!, path: path.isEmpty ? key : "\(path).\(key)")
            }
        }
        if let array = value as? [Any] {
            if array.isEmpty { return [MetadataEntry(id: path, value: "[]")] }
            return array.enumerated().flatMap { index, element in
                metadataEntries(element, path: "\(path)[\(index)]")
            }
        }
        return [MetadataEntry(id: path, value: String(describing: value))]
    }

    private func selectAdjacentMedia(offset: Int) {
        let mediaItems = mediaIDs.compactMap { id in
            store.items.first { $0.id == id }
        }
        guard let index = mediaItems.firstIndex(where: { $0.id == item.id }),
              mediaItems.indices.contains(index + offset) else { return }
        addressRequest?.cancel()
        addressRequest = nil
        locationTitle = nil
        locationAddress = nil
        isResolvingAddress = false
        videoInfo = VideoInfoSummary()
        videoThumbnail = nil
        videoCaption = ""
        videoKeywords = ""
        savedVideoCaption = ""
        savedVideoKeywords = ""
        infoSaveError = nil
        item = mediaItems[index + offset]
        loadSelection()
        loadPhotoMetadata()
    }

    private func loadSelection() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playbackTime = 0
        playbackDuration = 0
        isPlaying = false
        isSeeking = false
        resumeAfterSeeking = false
        videoControlsVisible = true
        videoControlsHideAt = nil
        report = store.report(for: item)
        photoImage = item.kind == .photo ? UIImage(contentsOfFile: item.url.path) : nil
        player = item.kind == .video ? AVPlayer(url: item.url) : nil
        if let player {
            player.isMuted = isMuted
            player.play()
            isPlaying = true
            restartVideoControlsTimeout()
        }
    }

    private func share() {
        guard sharePayload == nil else { return }
        guard saveReport() else { return }
        guard FileManager.default.fileExists(atPath: item.url.path) else {
            errorMessage = "The file could not be found for sharing."
            return
        }
        // Share the original media file; the receiving app controls caption handling.
        var items: [Any] = [item.url]
        let reportText = MediaStore.normalizedReport(report)
        if !reportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(reportText)
        }
        shareSaveError = nil
        var videoLocation: CLLocation?
        if item.kind == .video, let details = store.videoCaptureDetails(for: item),
           let latitude = details.latitude, let longitude = details.longitude,
           latitude.isFinite, longitude.isFinite,
           CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) {
            videoLocation = CLLocation(latitude: latitude, longitude: longitude)
        }
        sharePayload = SharePayload(items: items, originalURL: item.url,
                                    originalKind: item.kind, videoLocation: videoLocation)
    }

    @discardableResult
    private func saveReport() -> Bool {
        if report == store.report(for: item) { return true }
        do {
            try store.saveReport(report, for: item)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func loadTemplates() {
        do {
            templates = try ReportTemplateStorage.load()
        } catch {
            errorMessage = "Saved report templates could not be read."
        }
    }

    private func persistTemplates() {
        do {
            try ReportTemplateStorage.save(templates)
        } catch {
            errorMessage = "Report templates could not be saved: \(error.localizedDescription)"
        }
    }

    private func saveTemplate() {
        let name = templateName.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = MediaStore.normalizedReport(report)
        guard !name.isEmpty, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var uniqueName = name
        var suffix = 2
        while templates.contains(where: { $0.name.localizedCaseInsensitiveCompare(uniqueName) == .orderedSame }) {
            uniqueName = "\(name) (\(suffix))"
            suffix += 1
        }
        templates.append(ReportTemplate(id: UUID(), name: uniqueName, content: content))
        templates.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persistTemplates()
    }

    private func chooseTemplate(_ template: ReportTemplate) {
        if report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            report = template.content
        } else if report != template.content {
            pendingTemplate = template
            showReplaceConfirmation = true
        }
    }

}

private struct ZoomablePhotoSurface: UIViewRepresentable {
    let image: UIImage
    let onSwipe: (UISwipeGestureRecognizer.Direction) -> Void

    func makeUIView(context: Context) -> ZoomablePhotoView {
        ZoomablePhotoView()
    }

    func updateUIView(_ view: ZoomablePhotoView, context: Context) {
        view.onSwipe = onSwipe
        view.display(image)
    }
}

private final class ZoomablePhotoView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var fittedSize: CGSize = .zero
    var onSwipe: ((UISwipeGestureRecognizer.Direction) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        addSubview(scrollView)
        scrollView.addSubview(imageView)

        for direction: UISwipeGestureRecognizer.Direction in [.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            swipe.delegate = self
            scrollView.addGestureRecognizer(swipe)
            // A fitted photo pages; an enlarged photo uses the native scroll pan.
            scrollView.panGestureRecognizer.require(toFail: swipe)
            if let pinch = scrollView.pinchGestureRecognizer {
                swipe.require(toFail: pinch)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        fittedSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard bounds.width > 0, bounds.height > 0,
              let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }
        if fittedSize != bounds.size {
            fittedSize = bounds.size
            scrollView.setZoomScale(1, animated: false)
            let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
            imageView.frame = CGRect(origin: .zero, size: size)
            scrollView.contentSize = size
            centerPhoto()
            scrollView.contentOffset = CGPoint(
                x: -scrollView.contentInset.left, y: -scrollView.contentInset.top
            )
        } else {
            centerPhoto()
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerPhoto() }

    private func centerPhoto() {
        let horizontal = max(0, (bounds.width - imageView.frame.width) / 2)
        let vertical = max(0, (bounds.height - imageView.frame.height) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if scrollView.contentInset != inset { scrollView.contentInset = inset }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01
    }

    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return }
        onSwipe?(gesture.direction)
    }
}

// Render only the video; playback controls belong to the floating SwiftUI bar.
private struct VideoPlaybackSurface: UIViewRepresentable {
    let player: AVPlayer
    let onSwipe: (UISwipeGestureRecognizer.Direction) -> Void

    func makeUIView(context: Context) -> VideoPlaybackView {
        let view = VideoPlaybackView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        view.onSwipe = onSwipe
        return view
    }

    func updateUIView(_ view: VideoPlaybackView, context: Context) {
        view.playerLayer.player = player
        view.onSwipe = onSwipe
    }

    static func dismantleUIView(_ view: VideoPlaybackView, coordinator: ()) {
        view.playerLayer.player = nil
        view.onSwipe = nil
    }
}

private final class VideoPlaybackView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var onSwipe: ((UISwipeGestureRecognizer.Direction) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            addGestureRecognizer(swipe)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        onSwipe?(gesture.direction)
    }
}

private struct VideoDurationBadge: View {
    let item: MediaItem
    @State private var durationText: String?

    var body: some View {
        ZStack {
            if let durationText {
                Text(durationText)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
            }
        }
        .allowsHitTesting(false)
        .task(id: item) {
            durationText = nil
            let asset = AVURLAsset(url: item.url)
            guard let duration = try? await asset.load(.duration),
                  !Task.isCancelled,
                  duration.seconds.isFinite, duration.seconds >= 0,
                  duration.seconds < Double(Int.max) else { return }
            let seconds = Int(duration.seconds.rounded(.down))
            durationText = seconds >= 3600 ?
                String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) :
                String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
    }
}

private struct CollectionThumbnail: View {
    private struct Request: Hashable {
        let item: MediaItem
        let size: MediaThumbnailSize
    }

    let item: MediaItem
    let pointSize: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var loadedThumbnail: MediaThumbnailCache.Entry?

    // Bucket nearby sizes to avoid new disk previews for every layout adjustment.
    private var thumbnailSize: MediaThumbnailSize {
        let pixels = min(2048, max(256, ceil(pointSize * displayScale / 128) * 128))
        return .collection(Int(pixels))
    }

    private var thumbnail: MediaThumbnailCache.Entry? {
        if let loadedThumbnail, loadedThumbnail.item == item, loadedThumbnail.size == thumbnailSize {
            return loadedThumbnail
        }
        return MediaThumbnailCache.shared.cached(for: item, size: thumbnailSize)
    }

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.2)
            if let image = thumbnail?.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: item.kind == .video ? "video.fill" : "photo")
                    .font(.title2)
            }
        }
        .task(id: Request(item: item, size: thumbnailSize)) {
            let size = thumbnailSize
            let entry = await MediaThumbnailCache.shared.load(item, size: size)
            guard !Task.isCancelled else { return }
            loadedThumbnail = entry
        }
    }
}

private struct MediaThumbnail: View {
    let item: MediaItem
    @State private var loadedThumbnail: MediaThumbnailCache.Entry?

    private var thumbnail: MediaThumbnailCache.Entry? {
        if let loadedThumbnail, loadedThumbnail.item == item { return loadedThumbnail }
        return MediaThumbnailCache.shared.cached(for: item)
    }

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.2)
            if let image = thumbnail?.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: item.kind == .video ? "video.fill" : "photo")
                    .font(.title2)
            }
        }
        .task(id: item) {
            if let loadedThumbnail, loadedThumbnail.item == item, loadedThumbnail.image != nil { return }
            // Retry transient decoding failures without requiring a Library re-entry.
            // Limit retries so an unreadable source cannot trigger an endless loop.
            for attempt in 0..<3 {
                guard !Task.isCancelled else { return }
                let entry = await MediaThumbnailCache.shared.load(item)
                guard !Task.isCancelled else { return }
                if entry.image != nil {
                    loadedThumbnail = entry
                    return
                }
                guard attempt < 2 else { return }
                do {
                    try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
                } catch {
                    return
                }
            }
        }
    }
}

private struct LibrarySharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct LibraryShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
    let originalURL: URL
    let originalKind: MediaItem.Kind
    let videoLocation: CLLocation?
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let originalURL: URL
    let originalKind: MediaItem.Kind
    let videoLocation: CLLocation?
    let onSaveError: @MainActor @Sendable (String) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let activity = SaveOriginalMediaActivity(mediaURL: originalURL, kind: originalKind,
                                                 videoLocation: videoLocation) {
            @MainActor @Sendable [onSaveError] message in
            onSaveError(message)
        }
        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: [activity]
        )
        // Use our original-file Save Image and Save Video actions to preserve capture location.
        controller.excludedActivityTypes = [.saveToCameraRoll]
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

@MainActor
private final class SaveOriginalMediaActivity: UIActivity {
    private let mediaURL: URL
    private let kind: MediaItem.Kind
    private let videoLocation: CLLocation?
    private let onError: @MainActor @Sendable (String) -> Void

    init(mediaURL: URL, kind: MediaItem.Kind, videoLocation: CLLocation?,
         onError: @escaping @MainActor @Sendable (String) -> Void) {
        self.mediaURL = mediaURL
        self.kind = kind
        self.videoLocation = videoLocation
        self.onError = onError
        super.init()
    }

    override class var activityCategory: UIActivity.Category { .action }
    override var activityType: UIActivity.ActivityType? {
        UIActivity.ActivityType(kind == .photo ? "WorkCamera.SaveOriginalPhoto" : "WorkCamera.SaveOriginalVideo")
    }
    override var activityTitle: String? { kind == .photo ? "Save Image" : "Save Video" }
    override var activityImage: UIImage? { UIImage(systemName: "square.and.arrow.down") }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        mediaURL.isFileURL
    }

    private func photoLocation() -> CLLocation? {
        guard let source = CGImageSourceCreateWithURL(mediaURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any],
              let latitude = (gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue,
              let longitude = (gps[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue,
              latitude.isFinite, longitude.isFinite,
              (0...90).contains(latitude), (0...180).contains(longitude),
              let latRef = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String)?.uppercased(),
              let lonRef = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String)?.uppercased(),
              ["N", "S"].contains(latRef), ["E", "W"].contains(lonRef) else { return nil }
        return CLLocation(latitude: latRef == "S" ? -latitude : latitude,
                          longitude: lonRef == "W" ? -longitude : longitude)
    }

    override func perform() {
        let originalURL = mediaURL
        let resourceType: PHAssetResourceType = kind == .photo ? .photo : .video
        // Read the photo's original GPS, or use the video's recording-start snapshot.
        // Never query the current device location while saving an existing capture.
        let captureLocation = kind == .photo ? photoLocation() : videoLocation
        let mediaName = kind == .photo ? "photo" : "video"
        Task { @MainActor in
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized else {
                onError("Photo library access is not allowed. Allow Work Camera to add photos in Settings.")
                activityDidFinish(false)
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.location = captureLocation
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = originalURL.lastPathComponent
                    options.shouldMoveFile = false
                    // Import original HEIC/MOV bytes without rendering or transcoding.
                    request.addResource(with: resourceType, fileURL: originalURL, options: options)
                }
                activityDidFinish(true)
            } catch {
                onError("The original \(mediaName) could not be saved: \(error.localizedDescription)")
                activityDidFinish(false)
            }
        }
    }
}
