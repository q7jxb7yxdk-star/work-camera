import AVFoundation
import AVKit
import Combine
import SwiftUI
import UIKit

@MainActor
struct VideoEditorView: View {
    let sourceURL: URL
    let save: (URL, Bool) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var asset: AVURLAsset?
    @State private var sourceTrack: AVAssetTrack?
    @State private var naturalSize = CGSize.zero
    @State private var sourceTransform = CGAffineTransform.identity
    @State private var frameDuration = CMTime(value: 1, timescale: 30)
    @State private var duration = 0.0
    @State private var sourceDuration = CMTime.zero
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var quarterTurns = 0
    @State private var left = 0.0
    @State private var right = 1.0
    @State private var top = 0.0
    @State private var bottom = 1.0
    @State private var removeAudio = false
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var showSaveOptions = false
    @State private var errorMessage: String?
    @State private var mode: EditorMode = .video
    @State private var thumbnails: [UIImage?] = Array(repeating: nil, count: 8)
    @State private var playbackTime = 0.0
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var pendingSeek: SeekRequest?
    @State private var seekTask: Task<Void, Never>?
    @State private var seekGeneration = 0
    @State private var scrubImage: UIImage?
    @State private var scrubGenerator: AVAssetImageGenerator?

    private struct SeekRequest {
        let seconds: Double
        let precise: Bool
    }

    private enum EditorMode { case video, crop }
    private var unavailable: Bool { isLoading || isSaving || player == nil }
    private var hasEdits: Bool {
        start > 0.0001 || end < duration - 0.0001 || quarterTurns != 0 ||
        left > 0 || right < 1 || top > 0 || bottom < 1 || removeAudio
    }
    private var cropRect: Binding<CGRect> {
        Binding(get: { CGRect(x: left, y: top, width: right - left, height: bottom - top) },
                set: { rect in
                    left = rect.minX; right = rect.maxX
                    top = rect.minY; bottom = rect.maxY
                })
    }
    private var previewSize: CGSize {
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(sourceTransform).size
        let rotated = quarterTurns % 2 == 0 ? oriented : CGSize(width: oriented.height, height: oriented.width)
        guard mode == .video else { return rotated }
        return CGSize(width: max(2, floor(rotated.width * (right - left) / 2) * 2),
                      height: max(2, floor(rotated.height * (bottom - top) / 2) * 2))
    }

    private var minimumLength: Double { min(duration, max(frameDuration.seconds, 0.1)) }
    private var selection: CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60_000),
                    end: CMTimeMinimum(sourceDuration, CMTime(seconds: end, preferredTimescale: 60_000)))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    if geometry.size.width > geometry.size.height {
                        landscapeHeader
                            .zIndex(1)
                        HStack(spacing: 24) {
                            Group {
                                if mode == .video {
                                    VStack(spacing: 0) {
                                        preview
                                        landscapePlaybackControls
                                            .frame(maxWidth: 760)
                                    }
                                } else {
                                    GeometryReader { previewGeometry in
                                        videoPreview(darkCropHandles: true)
                                            .overlay(alignment: .bottom) {
                                                landscapeCropPlaybackControls
                                                    .frame(maxWidth: 760)
                                                    .padding(.horizontal, 16)
                                                    .padding(.bottom, previewGeometry.size.height * 0.14)
                                            }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            landscapeModePicker
                        }
                        .padding(.horizontal, 0)
                    } else {
                        header.padding(.horizontal, 16)
                        VStack(spacing: 0) {
                            editingTools
                                .padding(.horizontal, 16)
                                .zIndex(1)
                            preview
                            playbackControls
                                .padding(.horizontal, 16)
                            modePicker
                                .padding(.horizontal, 16)
                        }
                    }
                }
            }
            .padding(.vertical, 0)
            .background(Color(uiColor: .systemBackground))
            .toolbar(.hidden, for: .navigationBar)
            .confirmationDialog("Save edited video as MOV", isPresented: $showSaveOptions, titleVisibility: .visible) {
                Button("Overwrite Original", role: .destructive) { persist(overwrite: true) }
                Button("Save as New Video") { persist(overwrite: false) }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Video Editing Error", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
            .overlay {
                if isSaving {
                    ZStack {
                        Color.black.opacity(0.4).ignoresSafeArea()
                        ProgressView("Saving video…").padding(24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        }
        .preferredColorScheme(nil)
        .interactiveDismissDisabled()
        .task { await loadVideo(); await loadThumbnails() }
        .onDisappear { cancelSeek(); player?.pause() }
        .onChange(of: removeAudio) { _, value in player?.isMuted = value }
        .onChange(of: mode) { _, _ in refreshPreview() }
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            guard !isSaving, !isScrubbing, seekTask == nil, let player else { return }
            let time = player.currentTime().seconds
            guard time.isFinite else { return }
            playbackTime = min(max(time, start), end)
            isPlaying = player.rate > 0
            if player.rate > 0, time < start || time >= end {
                updateTrim(seekTo: start)
            }
        }
    }

    private var header: some View {
        HStack {
            Button("Cancel") { player?.pause(); dismiss() }
                .disabled(isSaving)
                .editorCapsule()
            Spacer()
            Button("Done") { player?.pause(); isPlaying = false; showSaveOptions = true }
                .disabled(unavailable || !hasEdits)
                .editorCapsule()
        }
        .font(.headline)
    }

    private var landscapeHeader: some View {
        HStack(spacing: 12) {
            Button { player?.pause(); dismiss() } label: {
                Image(systemName: "xmark")
            }
            .editorCircle()
            .disabled(isSaving)
            .accessibilityLabel("Cancel")
            if mode == .video {
                audioButton.editorCircle()
            } else {
                HStack(spacing: 20) {
                    rotateButton
                    Button {
                        quarterTurns = 0; resetCrop(); refreshPreview()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .accessibilityLabel("Reset crop and rotation")
                }
                .font(.title3)
                .editorCapsule()
                .disabled(unavailable)
            }
            Spacer(minLength: 12)
            Button {
                player?.pause(); isPlaying = false; showSaveOptions = true
            } label: {
                Image(systemName: "checkmark")
            }
            .editorCircle()
            .disabled(unavailable || !hasEdits)
            .accessibilityLabel("Done")
        }
        .overlay {
            if mode == .video {
                Text("VIDEO").font(.subheadline).foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 16)
    }

    private var audioButton: some View {
        Button { removeAudio.toggle() } label: {
            Image(systemName: removeAudio ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(removeAudio ? Color.yellow : Color.primary)
        }
        .disabled(unavailable)
        .accessibilityLabel(removeAudio ? "Restore audio" : "Remove audio")
    }

    private var rotateButton: some View {
        Button {
            quarterTurns = (quarterTurns + 3) % 4
            resetCrop(); refreshPreview()
        } label: {
            Image(systemName: "rotate.left")
        }
        .accessibilityLabel("Rotate 90 degrees")
    }

    private var landscapeModePicker: some View {
        VStack(spacing: 24) {
            landscapeModeButton(.video, title: "Video", symbol: "video.fill")
            landscapeModeButton(.crop, title: "Crop", symbol: "crop.rotate")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 24)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
        .disabled(unavailable)
    }

    private func landscapeModeButton(_ value: EditorMode, title: String, symbol: String) -> some View {
        Button { mode = value } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 25))
                Text(title).font(.caption)
            }
            .frame(width: 64, height: 58)
            .foregroundStyle(mode == value ? Color.primary : Color.secondary)
            .overlay(alignment: .leading) {
                Image(systemName: "play.fill").font(.system(size: 6))
                    .foregroundStyle(.yellow).opacity(mode == value ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == value ? .isSelected : [])
    }

    private var landscapePlaybackControls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                playButton
                    .frame(width: 56)
                Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 52)
                EditorTrimTimeline(start: $start, end: $end, duration: duration,
                    minimumLength: minimumLength, endPreviewOffset: frameDuration.seconds,
                    playbackTime: playbackTime, thumbnails: thumbnails, subduedStyle: true,
                    seek: { seconds, precise in requestSeek(to: seconds, precise: precise) },
                    editingChanged: setScrubbing)
            }
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(timeLabel(start))
                Spacer()
                Text(timeLabel(end))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .disabled(unavailable)
    }

    private var landscapeCropPlaybackControls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                playButton
                    .foregroundStyle(.primary)
                EditorScrubSlider(time: playbackTime, start: start, end: end,
                    seek: { seconds, precise in requestSeek(to: seconds, precise: precise) },
                    editingChanged: setScrubbing)
            }
            HStack {
                Text(timeLabel(playbackTime))
                Spacer()
                Text(timeLabel(end))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.primary)
            .padding(.leading, 52).padding(.trailing, 12)
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .shadow(color: Color(uiColor: .systemBackground).opacity(0.9), radius: 5)
        .disabled(unavailable)
    }

    private var editingTools: some View {
        HStack {
            if mode == .video {
                Button {
                    removeAudio.toggle()
                } label: {
                    Image(systemName: removeAudio ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 28, height: 28)
                }
                .foregroundStyle(removeAudio ? Color.yellow : Color.primary)
                .editorCapsule()
                .accessibilityLabel(removeAudio ? "Restore audio" : "Remove audio")
                Spacer()
                Text("VIDEO").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(timeLabel(end - start)).font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    quarterTurns = (quarterTurns + 3) % 4
                    resetCrop()
                    refreshPreview()
                } label: {
                    Image(systemName: "rotate.left").frame(width: 28, height: 28)
                }
                .editorCapsule()
                .accessibilityLabel("Rotate 90 degrees")
                Spacer()
                Button("Reset") { quarterTurns = 0; resetCrop(); refreshPreview() }.editorCapsule()
            }
        }
        .buttonStyle(.plain)
        .disabled(unavailable)
    }

    private var preview: some View { videoPreview() }

    private func videoPreview(darkCropHandles: Bool = false) -> some View {
        GeometryReader { geometry in
            let available = CGSize(width: max(1, geometry.size.width), height: max(1, geometry.size.height))
            let size = previewSize
            let ratio = min(available.width / max(size.width, 1), available.height / max(size.height, 1))
            let fitted = CGSize(width: max(1, size.width * ratio), height: max(1, size.height * ratio))
            ZStack {
                if let player {
                    EditorVideoSurface(player: player)
                        .frame(width: fitted.width, height: fitted.height)
                    if let scrubImage {
                        Image(uiImage: scrubImage).resizable().scaledToFit()
                            .frame(width: fitted.width, height: fitted.height)
                            .background(.black)
                            .allowsHitTesting(false)
                    }
                    if mode == .crop {
                        EditorCropFrame(rect: cropRect, size: fitted, darkHandles: darkCropHandles) { player.pause(); isPlaying = false }
                            .frame(width: fitted.width, height: fitted.height)
                    }
                }
                if isLoading { ProgressView() }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        // Keep crop handles and the video surface from intercepting adjacent controls.
        .contentShape(Rectangle())
        .allowsHitTesting(!unavailable)
    }

    private var playbackControls: some View {
        VStack(spacing: 8) {
            if mode == .video {
                HStack(spacing: 8) {
                    playButton
                    EditorTrimTimeline(start: $start, end: $end, duration: duration,
                        minimumLength: minimumLength, endPreviewOffset: frameDuration.seconds,
                        playbackTime: playbackTime, thumbnails: thumbnails,
                        seek: { seconds, precise in requestSeek(to: seconds, precise: precise) },
                        editingChanged: setScrubbing)
                }
                HStack {
                    Text(timeLabel(start))
                    Spacer()
                    Text(timeLabel(end))
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    playButton
                    EditorScrubSlider(time: playbackTime, start: start, end: end,
                        seek: { seconds, precise in requestSeek(to: seconds, precise: precise) },
                        editingChanged: setScrubbing)
                    Text(timeLabel(playbackTime)).font(.caption.monospacedDigit())
                }
                Text("Drag the corners or edges to crop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(unavailable)
    }

    private var playButton: some View {
        Button {
            guard let player else { return }
            let needsPositioning = seekTask != nil || scrubImage != nil
            let selectedTime = playbackTime
            cancelSeek()
            if player.rate > 0 {
                player.pause()
                isPlaying = false
            } else {
                if needsPositioning {
                    player.seek(to: CMTime(seconds: selectedTime, preferredTimescale: 60_000),
                                toleranceBefore: .zero, toleranceAfter: .zero)
                } else if player.currentTime().seconds < start || player.currentTime().seconds >= end - frameDuration.seconds {
                    player.seek(to: selection.start, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                player.play()
                isPlaying = true
            }
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.title3).frame(width: 44, height: 52)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause video" : "Play selection")
    }

    private var modePicker: some View {
        HStack(spacing: 28) {
            modeButton(.video, title: "Video", symbol: "video")
            modeButton(.crop, title: "Crop", symbol: "crop.rotate")
        }
        .padding(.horizontal, 28).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
        .frame(maxWidth: .infinity)
        .disabled(unavailable)
    }

    private func modeButton(_ value: EditorMode, title: String, symbol: String) -> some View {
        Button { mode = value } label: {
            VStack(spacing: 4) {
                Image(systemName: "triangle.fill").font(.system(size: 6))
                    .rotationEffect(.degrees(180)).foregroundStyle(.yellow)
                    .opacity(mode == value ? 1 : 0)
                Image(systemName: symbol).font(.title2)
                Text(title).font(.caption)
            }
            .frame(minWidth: 60, minHeight: 52)
            .foregroundStyle(mode == value ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == value ? .isSelected : [])
    }

    private func timeLabel(_ value: Double) -> String {
        let seconds = max(0, value)
        return String(format: "%02d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    private func loadThumbnails() async {
        guard let asset, duration > 0 else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 120)
        for index in thumbnails.indices {
            guard !Task.isCancelled else { return }
            let time = CMTime(seconds: duration * (Double(index) + 0.5) / Double(thumbnails.count), preferredTimescale: 600)
            do {
                let result = try await generator.image(at: time)
                guard !Task.isCancelled else { return }
                thumbnails[index] = UIImage(cgImage: result.image)
            } catch {
                if Task.isCancelled { return }
                // Keep a placeholder when a single sample cannot be decoded.
            }
        }
    }

    private func resetCrop() { left = 0; right = 1; top = 0; bottom = 1 }

    private func loadVideo() async {
        defer { isLoading = false }
        do {
            let source = AVURLAsset(url: sourceURL)
            guard let track = try await source.loadTracks(withMediaType: .video).first else {
                throw VideoEditingError.invalidSource
            }
            let time = try await source.load(.duration)
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let rate = try await track.load(.nominalFrameRate)
            let minimumFrame = try await track.load(.minFrameDuration)
            guard time.seconds.isFinite, time.seconds > 0, size.width > 0, size.height > 0 else {
                throw VideoEditingError.invalidSource
            }
            asset = source
            sourceTrack = track
            naturalSize = size
            sourceTransform = transform
            if minimumFrame.isNumeric, minimumFrame.seconds > 0 {
                frameDuration = minimumFrame
            } else if rate.isFinite, rate > 0 {
                frameDuration = CMTime(seconds: 1 / Double(rate), preferredTimescale: 60_000)
            }
            duration = time.seconds
            sourceDuration = time
            end = duration
            let playbackItem = AVPlayerItem(asset: source)
            playbackItem.videoComposition = videoComposition(track: track, timeRange: CMTimeRange(start: .zero, duration: time))
            playbackItem.forwardPlaybackEndTime = time
            player = AVPlayer(playerItem: playbackItem)
        } catch { errorMessage = error.localizedDescription }
    }

    private func setScrubbing(_ editing: Bool) {
        if editing {
            guard !isScrubbing else { return }
            // A new drag must not wait behind the previous precise player seek.
            let previousImage = scrubImage
            cancelSeek(preserveGenerator: true)
            scrubImage = previousImage
            isScrubbing = true
            player?.pause()
            isPlaying = false
            prepareScrubGenerator()
        } else {
            guard isScrubbing else { return }
            isScrubbing = false
            requestSeek(to: playbackTime, precise: true)
        }
    }

    private func updateTrim(seekTo seconds: Double) {
        cancelSeek()
        requestSeek(to: seconds, precise: true)
    }

    private func requestSeek(to seconds: Double, precise: Bool) {
        guard let player, player.currentItem != nil, !isSaving else { return }
        player.pause()
        isPlaying = false
        // Preview the last included frame rather than seeking beyond the selected movie.
        let lastFrame = max(start, end - frameDuration.seconds)
        playbackTime = min(max(seconds, start), lastFrame)
        player.currentItem?.forwardPlaybackEndTime = selection.end
        player.currentItem?.reversePlaybackEndTime = selection.start
        // Keep the newest target while one seek is in flight.
        pendingSeek = SeekRequest(seconds: playbackTime, precise: precise && !isScrubbing)
        guard seekTask == nil else { return }
        let generation = seekGeneration
        seekTask = Task { @MainActor in
            defer {
                if generation == seekGeneration { seekTask = nil }
            }
            while !Task.isCancelled, generation == seekGeneration, let request = pendingSeek {
                pendingSeek = nil
                let time = CMTime(seconds: request.seconds, preferredTimescale: 60_000)
                if !request.precise {
                    // Display decoded frames directly while dragging; do not wait for AVPlayerLayer.
                    prepareScrubGenerator()
                    guard let generator = scrubGenerator else { continue }
                    generator.requestedTimeToleranceBefore = CMTime(
                        seconds: min(0.1, max(0, request.seconds - start)), preferredTimescale: 600)
                    generator.requestedTimeToleranceAfter = CMTime(
                        seconds: min(0.1, max(0, end - request.seconds)), preferredTimescale: 600)
                    do {
                        let result = try await generator.image(at: time)
                        guard !Task.isCancelled, generation == seekGeneration else { return }
                        // Show every completed sample, then decode the newest queued position.
                        scrubImage = scrubPreviewImage(result.image)
                    } catch {
                        guard !Task.isCancelled, generation == seekGeneration else { return }
                        // Fall back to the player if this sample cannot be decoded.
                        _ = await player.seek(to: time,
                            toleranceBefore: generator.requestedTimeToleranceBefore,
                            toleranceAfter: generator.requestedTimeToleranceAfter)
                        guard !Task.isCancelled, generation == seekGeneration else { return }
                        scrubImage = nil
                    }
                } else {
                    // Keep the last preview frame visible until the player finishes the final seek.
                    let finished = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                    guard !Task.isCancelled, generation == seekGeneration else { return }
                    if finished, pendingSeek == nil, !isScrubbing {
                        scrubImage = nil
                    }
                }
            }
        }
    }

    private func prepareScrubGenerator() {
        guard scrubGenerator == nil, let asset else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        // Decode a small source frame without invoking the full-resolution video compositor.
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        scrubGenerator = generator
    }

    private func scrubPreviewImage(_ frame: CGImage) -> UIImage {
        var image = UIImage(cgImage: frame)
        if quarterTurns != 0 {
            let sourceSize = image.size
            let rotation = CGAffineTransform(rotationAngle: CGFloat(quarterTurns) * .pi / 2)
            let bounds = CGRect(origin: .zero, size: sourceSize).applying(rotation)
            let size = quarterTurns % 2 == 0 ? sourceSize : CGSize(width: sourceSize.height, height: sourceSize.width)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let sourceImage = image
            image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                context.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
                context.cgContext.concatenate(rotation)
                sourceImage.draw(in: CGRect(origin: .zero, size: sourceSize))
            }
        }
        // Crop mode shows the complete frame beneath its interactive crop outline.
        if mode == .video, let pixels = image.cgImage {
            let bounds = CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)
            let crop = CGRect(x: left * bounds.width, y: top * bounds.height,
                              width: (right - left) * bounds.width, height: (bottom - top) * bounds.height)
                .integral.intersection(bounds)
            if let cropped = pixels.cropping(to: crop) { image = UIImage(cgImage: cropped) }
        }
        return image
    }

    private func cancelSeek(preserveGenerator: Bool = false) {
        seekGeneration += 1
        seekTask?.cancel()
        if seekTask != nil { player?.currentItem?.cancelPendingSeeks() }
        seekTask = nil
        pendingSeek = nil
        scrubGenerator?.cancelAllCGImageGeneration()
        if !preserveGenerator { scrubGenerator = nil }
        scrubImage = nil
        isScrubbing = false
    }

    private func refreshPreview() {
        guard let sourceTrack, let playbackItem = player?.currentItem else { return }
        // Direct frame previews can be ahead of the player's last completed seek.
        let time = min(max(playbackTime, start), max(start, end - frameDuration.seconds))
        cancelSeek()
        player?.pause()
        playbackItem.videoComposition = videoComposition(track: sourceTrack,
            timeRange: CMTimeRange(start: .zero, duration: sourceDuration), applyCrop: mode != .crop)
        requestSeek(to: time, precise: true)
    }

    private func videoComposition(track: AVAssetTrack, timeRange: CMTimeRange, applyCrop: Bool = true) -> AVVideoComposition {
        // Normalize the recorded orientation, then rotate and crop in displayed coordinates.
        let sourceRect = CGRect(origin: .zero, size: naturalSize)
        let orientedBounds = sourceRect.applying(sourceTransform)
        let orientation = sourceTransform.concatenating(CGAffineTransform(
            translationX: -orientedBounds.minX, y: -orientedBounds.minY))
        let rotation = CGAffineTransform(rotationAngle: CGFloat(quarterTurns) * .pi / 2)
        let rotatedBounds = CGRect(origin: .zero, size: orientedBounds.size).applying(rotation)
        let rotated = orientation.concatenating(rotation).concatenating(CGAffineTransform(
            translationX: -rotatedBounds.minX, y: -rotatedBounds.minY))
        // Even output dimensions are suitable for HEVC; use the same pixels in preview/export.
        let width = max(2, floor(rotatedBounds.width * (applyCrop ? right - left : 1) / 2) * 2)
        let height = max(2, floor(rotatedBounds.height * (applyCrop ? bottom - top : 1) / 2) * 2)
        let transform = rotated.concatenating(CGAffineTransform(
            translationX: applyCrop ? -rotatedBounds.width * left : 0,
            y: applyCrop ? -rotatedBounds.height * top : 0))
        var layerConfiguration = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        layerConfiguration.setTransform(transform, at: timeRange.start)
        let layer = AVVideoCompositionLayerInstruction(configuration: layerConfiguration)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            layerInstructions: [layer], timeRange: timeRange))
        let configuration = AVVideoComposition.Configuration(
            frameDuration: frameDuration,
            instructions: [instruction],
            renderSize: CGSize(width: width, height: height))
        return AVVideoComposition(configuration: configuration)
    }

    private func persist(overwrite: Bool) {
        guard !isSaving, let asset, let sourceTrack else { return }
        cancelSeek()
        isSaving = true
        player?.pause()
        Task { @MainActor in
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".MOV")
            defer {
                try? FileManager.default.removeItem(at: output)
                isSaving = false
            }
            do {
                let composition = AVMutableComposition()
                guard let video = composition.addMutableTrack(withMediaType: .video,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw VideoEditingError.invalidSource
                }
                try video.insertTimeRange(selection, of: sourceTrack, at: .zero)
                if !removeAudio {
                    for track in try await asset.loadTracks(withMediaType: .audio) {
                        let available = try await track.load(.timeRange)
                        let overlap = CMTimeRangeGetIntersection(selection, otherRange: available)
                        guard overlap.duration.seconds > 0 else { continue }
                        guard let audio = composition.addMutableTrack(withMediaType: .audio,
                                                                       preferredTrackID: kCMPersistentTrackID_Invalid) else {
                            throw VideoEditingError.invalidSource
                        }
                        try audio.insertTimeRange(overlap, of: track, at: CMTimeSubtract(overlap.start, selection.start))
                    }
                }
                guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality) else {
                    throw VideoEditingError.exportUnavailable
                }
                exporter.videoComposition = videoComposition(track: video,
                    timeRange: CMTimeRange(start: .zero, duration: selection.duration))
                exporter.metadata = try await asset.load(.metadata)
                try await exporter.export(to: output, as: .mov)
                // Release the editor's source reader before replacing the original file.
                player?.replaceCurrentItem(with: nil)
                try await save(output, overwrite)
                dismiss()
            } catch {
                if player?.currentItem == nil {
                    let playbackItem = AVPlayerItem(asset: asset)
                    playbackItem.videoComposition = videoComposition(track: sourceTrack,
                        timeRange: CMTimeRange(start: .zero, duration: sourceDuration), applyCrop: mode != .crop)
                    player?.replaceCurrentItem(with: playbackItem)
                    updateTrim(seekTo: start)
                }
                errorMessage = error.localizedDescription
            }
        }
    }
}

private enum VideoEditingError: LocalizedError {
    case invalidSource
    case exportUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidSource: "This video could not be loaded for editing."
        case .exportUnavailable: "HEVC export is unavailable for this video. The original was not changed."
        }
    }
}

private extension View {
    func editorCircle() -> some View {
        self
            .font(.system(size: 22, weight: .medium))
            .frame(width: 52, height: 52)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
            .buttonStyle(.plain)
    }

    func editorCapsule() -> some View {
        self
            .padding(.horizontal, 18).frame(minHeight: 44)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
            .buttonStyle(.plain)
    }
}

private struct EditorVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> EditorVideoLayerView {
        let view = EditorVideoLayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: EditorVideoLayerView, context: Context) { view.playerLayer.player = player }

    static func dismantleUIView(_ view: EditorVideoLayerView, coordinator: ()) { view.playerLayer.player = nil }
}

private final class EditorVideoLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct EditorScrubSlider: View {
    let time: Double
    let start: Double
    let end: Double
    let seek: (Double, Bool) -> Void
    let editingChanged: (Bool) -> Void
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 24)
            let length = max(end - start, 0.001)
            let fraction = min(max((time - start) / length, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 4)
                Capsule().fill(Color.primary).frame(width: width * fraction, height: 4)
                Circle().fill(Color(uiColor: .systemBackground))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25)))
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .frame(width: 24, height: 24)
                    .offset(x: width * fraction - 12)
            }
            .frame(width: width, height: 44)
            .padding(.horizontal, 12)
            .frame(width: geometry.size.width, height: 44)
            .contentShape(Rectangle())
            .coordinateSpace(name: "cropScrubSlider")
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("cropScrubSlider"))
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        editingChanged(true)
                    }
                    let position = min(max((value.location.x - 12) / width, 0), 1)
                    seek(start + Double(position) * length, false)
                }
                .onEnded { _ in
                    isDragging = false
                    editingChanged(false)
                })
        }
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Video position")
        .accessibilityValue(String(format: "%.2f seconds", time))
        .accessibilityAdjustableAction { direction in
            seek(min(max(time + (direction == .increment ? 0.1 : -0.1), start), end), true)
        }
    }
}

private struct EditorTrimTimeline: View {
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double
    let minimumLength: Double
    let endPreviewOffset: Double
    let playbackTime: Double
    let thumbnails: [UIImage?]
    var subduedStyle = false
    let seek: (Double, Bool) -> Void
    let editingChanged: (Bool) -> Void
    private enum DragTarget { case start, end, playback }
    @State private var dragTarget: DragTarget?
    @State private var dragOriginTime = 0.0
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            // Reserve room inside the container for each handle's full touch area.
            let handleInset: CGFloat = 22
            let width = max(1, geometry.size.width - handleInset * 2)
            let total = max(duration, 0.001)
            let startX = width * start / total
            let endX = width * end / total
            let selectedWidth = max(1, endX - startX)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(thumbnails.indices, id: \.self) { index in
                        Group {
                            if let image = thumbnails[index] {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                Rectangle().fill(Color.secondary.opacity(0.25))
                                    .overlay(Image(systemName: "film").foregroundStyle(.secondary))
                            }
                        }
                        .frame(width: width / CGFloat(max(1, thumbnails.count)), height: 52)
                        .clipped()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .allowsHitTesting(false)
                Path { path in
                    path.addRect(CGRect(x: 0, y: 0, width: startX, height: 52))
                    path.addRect(CGRect(x: endX, y: 0, width: max(0, width - endX), height: 52))
                }.fill(.black.opacity(0.6)).allowsHitTesting(false)
                Rectangle().stroke(subduedStyle ? Color.primary.opacity(0.2) : .yellow, lineWidth: 3)
                    .frame(width: selectedWidth, height: 52).offset(x: startX)
                    .allowsHitTesting(false)
                // Playback accessibility is separate from the two trim endpoints.
                Color.clear.contentShape(Rectangle())
                    .accessibilityLabel("Video position")
                    .accessibilityValue(String(format: "%.2f seconds", playbackTime))
                    .accessibilityAdjustableAction { direction in
                        seek(min(max(playbackTime + (direction == .increment ? 0.1 : -0.1), start), end), true)
                    }
                Capsule().fill(.white).frame(width: 3, height: 50)
                    .shadow(color: .black.opacity(0.7), radius: 2)
                    .offset(x: min(max(width * playbackTime / total, startX), endX) - 1.5, y: 1)
                    .allowsHitTesting(false)
                trimHandle(isStart: true).position(x: startX, y: 26)
                trimHandle(isStart: false).position(x: endX, y: 26)
            }
            .frame(width: width, height: 52)
            .padding(.horizontal, handleInset)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .coordinateSpace(name: "editorTimeline")
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("editorTimeline"))
                .onChanged { value in
                    if dragTarget == nil {
                        let initialX = value.startLocation.x - handleInset
                        let startDistance = abs(initialX - startX)
                        let endDistance = abs(initialX - endX)
                        if min(startDistance, endDistance) <= handleInset {
                            dragTarget = startDistance <= endDistance ? .start : .end
                            dragOriginTime = dragTarget == .start ? start : end
                        } else {
                            dragTarget = .playback
                        }
                        beginScrubbing()
                    }
                    switch dragTarget {
                    case .start, .end:
                        adjustHandle(isStart: dragTarget == .start,
                            to: dragOriginTime + Double(value.translation.width / width) * total,
                            precise: false)
                    case .playback:
                        let position = Double((value.location.x - handleInset) / width) * total
                        seek(min(max(position, start), end), false)
                    case nil:
                        break
                    }
                }
                .onEnded { _ in
                    dragTarget = nil
                    endScrubbing()
                })
        }
        .frame(height: 64)
    }

    private func trimHandle(isStart: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(subduedStyle ? Color(uiColor: .secondarySystemFill) : .yellow)
                .frame(width: 16, height: 58)
            Image(systemName: isStart ? "chevron.left" : "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(subduedStyle ? Color.primary : .black)
        }
        .frame(width: 44, height: 64).contentShape(Rectangle())
        .accessibilityLabel(isStart ? "Trim start" : "Trim end")
        .accessibilityValue(String(format: "%.2f seconds", isStart ? start : end))
        .accessibilityAdjustableAction { direction in
            adjustHandle(isStart: isStart,
                to: (isStart ? start : end) + (direction == .increment ? 0.1 : -0.1), precise: true)
        }
    }

    private func beginScrubbing() {
        guard !isDragging else { return }
        isDragging = true
        editingChanged(true)
    }

    private func endScrubbing() {
        isDragging = false
        editingChanged(false)
    }

    private func adjustHandle(isStart: Bool, to time: Double, precise: Bool) {
        if isStart {
            start = min(max(0, time), max(0, end - minimumLength))
            seek(start, precise)
        } else {
            end = max(min(duration, time), min(duration, start + minimumLength))
            seek(max(start, end - endPreviewOffset), precise)
        }
    }
}

private struct EditorCropFrame: View {
    @Binding var rect: CGRect
    let size: CGSize
    var darkHandles = false
    let beganDragging: () -> Void
    @State private var dragOrigin: CGRect?

    var body: some View {
        let selection = CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                               width: rect.width * size.width, height: rect.height * size.height)
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(selection)
            }
            .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            Rectangle().stroke(darkHandles ? Color.primary : .black.opacity(0.7), lineWidth: 3)
                .frame(width: selection.width, height: selection.height)
                .offset(x: selection.minX, y: selection.minY).allowsHitTesting(false)
            Rectangle().stroke(darkHandles ? Color.clear : .white, lineWidth: 1)
                .frame(width: selection.width, height: selection.height)
                .offset(x: selection.minX, y: selection.minY).allowsHitTesting(false)
            Path { path in
                for fraction in [CGFloat(1.0 / 3), CGFloat(2.0 / 3)] {
                    let x = selection.minX + selection.width * fraction
                    let y = selection.minY + selection.height * fraction
                    path.move(to: CGPoint(x: x, y: selection.minY))
                    path.addLine(to: CGPoint(x: x, y: selection.maxY))
                    path.move(to: CGPoint(x: selection.minX, y: y))
                    path.addLine(to: CGPoint(x: selection.maxX, y: y))
                }
            }.stroke(.white.opacity(darkHandles && dragOrigin == nil ? 0 : 0.6), lineWidth: 0.5).allowsHitTesting(false)
            ForEach(0..<8) { handle in
                cropHandle(handle, selection: selection)
            }
        }
        .coordinateSpace(name: "editorCropFrame")
    }

    private func cropHandle(_ index: Int, selection: CGRect) -> some View {
        // Four corners, then left/right/top/bottom edge midpoints.
        let positions = [
            CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.minY),
            CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.maxX, y: selection.maxY),
            CGPoint(x: selection.minX, y: selection.midY), CGPoint(x: selection.maxX, y: selection.midY),
            CGPoint(x: selection.midX, y: selection.minY), CGPoint(x: selection.midX, y: selection.maxY)
        ]
        let labels = ["Top left", "Top right", "Bottom left", "Bottom right", "Left", "Right", "Top", "Bottom"]
        return ZStack {
            Path { path in
                if index < 4 {
                    let x: CGFloat = index % 2 == 0 ? 1 : -1
                    let y: CGFloat = index < 2 ? 1 : -1
                    path.move(to: CGPoint(x: 22, y: 22 + y * 16))
                    path.addLine(to: CGPoint(x: 22, y: 22))
                    path.addLine(to: CGPoint(x: 22 + x * 16, y: 22))
                } else if index < 6 {
                    path.move(to: CGPoint(x: 22, y: 12)); path.addLine(to: CGPoint(x: 22, y: 32))
                } else {
                    path.move(to: CGPoint(x: 12, y: 22)); path.addLine(to: CGPoint(x: 32, y: 22))
                }
            }.stroke(darkHandles ? Color.primary : .white,
                     style: StrokeStyle(lineWidth: darkHandles ? 5 : 4, lineCap: .square))
                .shadow(color: darkHandles ? .clear : .black, radius: 1)
        }
        .frame(width: 44, height: 44).contentShape(Rectangle())
        .position(positions[index])
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("editorCropFrame"))
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                if dragOrigin == nil { dragOrigin = rect; beganDragging() }
                guard let origin = dragOrigin else { return }
                rect = movedRect(origin, handle: index,
                    dx: value.translation.width / size.width, dy: value.translation.height / size.height)
            }
            .onEnded { _ in dragOrigin = nil })
        .accessibilityLabel("Crop \(labels[index])")
        .accessibilityAdjustableAction { direction in
            beganDragging()
            let step: CGFloat = direction == .increment ? 0.01 : -0.01
            rect = movedRect(rect, handle: index, dx: step, dy: step)
        }
    }

    private func movedRect(_ origin: CGRect, handle: Int, dx: CGFloat, dy: CGFloat) -> CGRect {
        let movesLeft = handle == 0 || handle == 2 || handle == 4
        let movesRight = handle == 1 || handle == 3 || handle == 5
        let movesTop = handle == 0 || handle == 1 || handle == 6
        let movesBottom = handle == 2 || handle == 3 || handle == 7
        let left = movesLeft ? min(max(0, origin.minX + dx), origin.maxX - 0.05) : origin.minX
        let right = movesRight ? max(min(1, origin.maxX + dx), origin.minX + 0.05) : origin.maxX
        let top = movesTop ? min(max(0, origin.minY + dy), origin.maxY - 0.05) : origin.minY
        let bottom = movesBottom ? max(min(1, origin.maxY + dy), origin.minY + 0.05) : origin.maxY
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
