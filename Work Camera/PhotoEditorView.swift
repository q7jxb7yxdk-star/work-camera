import ImageIO
import PencilKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PhotoEditorView: View {
    let sourceURL: URL
    let save: (Data, Bool) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage
    @State private var canvas = ResizingMarkupCanvas()
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var mode: Mode = .markup
    @State private var inkColor: Color = .red
    @State private var tool: DrawingTool = .pen
    @State private var showSaveOptions = false
    @State private var errorMessage: String?
    @State private var isSaving = false

    private enum Mode { case crop, markup }
    private enum DrawingTool: String, CaseIterable { case pen = "Pen", marker = "Marker", eraser = "Eraser" }

    init(image: UIImage, sourceURL: URL, save: @escaping (Data, Bool) throws -> Void) {
        self.sourceURL = sourceURL
        self.save = save
        _image = State(initialValue: Self.render(size: image.size) { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) })
    }

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            NavigationStack {
                Group {
                    if isLandscape {
                        HStack(spacing: 16) {
                            photoPreview
                            landscapeControls
                                .frame(width: 216)
                        }
                        .padding(8)
                    } else {
                        VStack(spacing: 16) {
                            photoPreview
                            editingOptions(isLandscape: false)
                                .padding(.horizontal, 16)
                            modeControls(isLandscape: false)
                                .padding(.horizontal, 16)
                        }
                        .padding(.vertical, 16)
                    }
                }
                .background(Color(uiColor: .systemBackground))
                .navigationTitle("Edit Photo")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !isLandscape {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { showSaveOptions = true }.disabled(isSaving)
                        }
                    }
                }
                .toolbar(isLandscape ? .hidden : .visible, for: .navigationBar)
                .confirmationDialog("Save edited photo as HEIC", isPresented: $showSaveOptions, titleVisibility: .visible) {
                    Button("Overwrite Original", role: .destructive) { persist(overwrite: true) }
                    Button("Save as New Photo") { persist(overwrite: false) }
                    Button("Cancel", role: .cancel) {}
                }
                .alert("Could Not Save Photo", isPresented: Binding(
                    get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
                )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
            }
        }
        .preferredColorScheme(nil)
        .interactiveDismissDisabled()
    }

    private var photoPreview: some View {
        GeometryReader { geometry in
            let ratio = min(geometry.size.width / image.size.width, geometry.size.height / image.size.height)
            let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            ZStack {
                Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                MarkupCanvas(canvas: canvas, enabled: mode == .markup, tool: selectedTool)
                    .frame(width: size.width, height: size.height)
                if mode == .crop {
                    CropSelection(rect: $crop, size: size)
                        .frame(width: size.width, height: size.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var landscapeControls: some View {
        VStack(spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modeControls(isLandscape: true)
                    Divider()
                    editingOptions(isLandscape: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { showSaveOptions = true }.disabled(isSaving)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func editingOptions(isLandscape: Bool) -> some View {
        if mode == .markup {
            if isLandscape {
                VStack(alignment: .leading, spacing: 12) {
                    drawingToolPicker
                    HStack {
                        ColorPicker("Ink color", selection: $inkColor, supportsOpacity: false)
                            .labelsHidden()
                        Spacer()
                        Button("Clear") { canvas.drawing = PKDrawing() }
                    }
                }
            } else {
                HStack {
                    drawingToolPicker
                    ColorPicker("Ink color", selection: $inkColor, supportsOpacity: false)
                        .labelsHidden()
                    Button("Clear") { canvas.drawing = PKDrawing() }
                }
            }
        } else {
            if isLandscape {
                VStack(alignment: .leading, spacing: 12) {
                    cropInstructions
                    Button("Apply Crop") { applyCrop() }
                }
            } else {
                HStack {
                    cropInstructions
                    Spacer()
                    Button("Apply Crop") { applyCrop() }
                }
            }
        }
    }

    private var drawingToolPicker: some View {
        Picker("Drawing tool", selection: $tool) {
            ForEach(DrawingTool.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var cropInstructions: some View {
        Text("Drag the corners to crop.").font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func modeControls(isLandscape: Bool) -> some View {
        if isLandscape {
            VStack(alignment: .leading, spacing: 16) { modeButtons }
                .buttonStyle(.borderless)
        } else {
            HStack(spacing: 30) { modeButtons }
                .buttonStyle(.borderless)
        }
    }

    private var modeButtons: some View {
        Group {
            Button { mode = .crop } label: { Label("Crop", systemImage: "crop") }
                .tint(mode == .crop ? Color.accentColor : Color.primary)
            Button { rotate() } label: { Label("Rotate", systemImage: "rotate.right") }
                .tint(.primary)
            Button {
                if mode == .crop { applyCrop() }
                mode = .markup
            } label: { Label("Markup", systemImage: "pencil.tip.crop.circle") }
                .tint(mode == .markup ? Color.accentColor : Color.primary)
        }
    }

    private var selectedTool: PKTool {
        switch tool {
        case .pen: PKInkingTool(.pen, color: UIColor(inkColor), width: 4)
        case .marker: PKInkingTool(.marker, color: UIColor(inkColor), width: 16)
        case .eraser: PKEraserTool(.bitmap)
        }
    }

    private static func render(size: CGSize, draw: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image(actions: draw)
    }

    private func markedImage() -> UIImage {
        guard !canvas.drawing.strokes.isEmpty, canvas.bounds.width > 0 else { return image }
        let overlay = canvas.drawing.image(from: canvas.bounds, scale: image.size.width / canvas.bounds.width)
        return Self.render(size: image.size) { _ in
            let rect = CGRect(origin: .zero, size: image.size)
            image.draw(in: rect)
            overlay.draw(in: rect)
        }
    }

    private func croppedImage(_ source: UIImage) -> UIImage {
        guard let cgImage = source.cgImage else { return source }
        let rect = CGRect(x: crop.minX * CGFloat(cgImage.width), y: crop.minY * CGFloat(cgImage.height),
                          width: crop.width * CGFloat(cgImage.width), height: crop.height * CGFloat(cgImage.height))
            .integral.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard let cropped = cgImage.cropping(to: rect) else { return source }
        return UIImage(cgImage: cropped)
    }

    private func applyCrop() {
        image = croppedImage(markedImage())
        canvas.drawing = PKDrawing()
        crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    private func rotate() {
        // Flatten annotations before changing image coordinates.
        let source = mode == .crop ? croppedImage(markedImage()) : markedImage()
        let size = CGSize(width: source.size.height, height: source.size.width)
        image = Self.render(size: size) { context in
            context.cgContext.translateBy(x: size.width, y: 0)
            context.cgContext.rotate(by: .pi / 2)
            source.draw(in: CGRect(origin: .zero, size: source.size))
        }
        canvas.drawing = PKDrawing()
        crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    private func persist(overwrite: Bool) {
        isSaving = true
        defer { isSaving = false }
        do {
            let output = mode == .crop ? croppedImage(markedImage()) : markedImage()
            let data = try encodeHEIC(output)
            try save(data, overwrite)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private func encodeHEIC(_ image: UIImage) throws -> Data {
        guard let cgImage = image.cgImage else { throw PhotoEditingError.encodingFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.heic.identifier as CFString, 1, nil)
        else { throw PhotoEditingError.encodingFailed }
        var properties: [String: Any] = [:]
        if let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            // Keep capture details and GPS, but do not carry obsolete source image structures.
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary] {
                properties[key as String] = original[key as String]
            }
        }
        properties[kCGImagePropertyOrientation as String] = 1
        properties[kCGImagePropertyPixelWidth as String] = cgImage.width
        properties[kCGImagePropertyPixelHeight as String] = cgImage.height
        properties[kCGImageDestinationLossyCompressionQuality as String] = 1.0
        var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = cgImage.width
        exif[kCGImagePropertyExifPixelYDimension as String] = cgImage.height
        exif.removeValue(forKey: kCGImagePropertyExifMakerNote as String)
        properties[kCGImagePropertyExifDictionary as String] = exif
        var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        properties[kCGImagePropertyTIFFDictionary as String] = tiff
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let verification = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(verification) as String? == UTType.heic.identifier
        else { throw PhotoEditingError.encodingFailed }
        return data as Data
    }
}

private enum PhotoEditingError: LocalizedError {
    case encodingFailed
    var errorDescription: String? { "The edited photo could not be encoded as HEIC. The original photo was not changed." }
}

private struct CropSelection: View {
    @Binding var rect: CGRect
    let size: CGSize
    @State private var dragStart: CGRect?

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
            Rectangle().stroke(.white, lineWidth: 1)
                .frame(width: selection.width, height: selection.height)
                .offset(x: selection.minX, y: selection.minY)
                .allowsHitTesting(false)
            ForEach(0..<4) { corner in
                let right = corner % 2 == 1
                let bottom = corner >= 2
                Circle().fill(.white).frame(width: 14, height: 14)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
                    .position(x: right ? selection.maxX : selection.minX, y: bottom ? selection.maxY : selection.minY)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard size.width > 0, size.height > 0 else { return }
                        if dragStart == nil { dragStart = rect }
                        guard let start = dragStart else { return }
                        let dx = value.translation.width / size.width
                        let dy = value.translation.height / size.height
                        let left = right ? start.minX : min(max(0, start.minX + dx), start.maxX - 0.05)
                        let top = bottom ? start.minY : min(max(0, start.minY + dy), start.maxY - 0.05)
                        let endX = right ? max(min(1, start.maxX + dx), start.minX + 0.05) : start.maxX
                        let endY = bottom ? max(min(1, start.maxY + dy), start.minY + 0.05) : start.maxY
                        rect = CGRect(x: left, y: top, width: endX - left, height: endY - top)
                    }.onEnded { _ in dragStart = nil })
                    .accessibilityLabel("Crop corner \(corner + 1)")
            }
        }
    }
}

private struct MarkupCanvas: UIViewRepresentable {
    let canvas: ResizingMarkupCanvas
    let enabled: Bool
    let tool: PKTool

    func makeUIView(context: Context) -> ResizingMarkupCanvas {
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.drawingPolicy = .anyInput
        return canvas
    }

    func updateUIView(_ view: ResizingMarkupCanvas, context: Context) {
        view.isUserInteractionEnabled = enabled
        view.tool = tool
    }
}

// Keep annotations aligned when the editor changes size or device orientation.
private final class ResizingMarkupCanvas: PKCanvasView {
    private var previousSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if previousSize.width > 0, previousSize.height > 0, size != previousSize {
            drawing = drawing.transformed(using: CGAffineTransform(
                scaleX: size.width / previousSize.width, y: size.height / previousSize.height
            ))
        }
        previousSize = size
    }
}
