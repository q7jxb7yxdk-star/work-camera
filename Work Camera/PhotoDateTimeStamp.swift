import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

nonisolated enum PhotoDateTimeStamp {
    static func text(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func apply(to data: Data, text: String) throws -> Data {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                  let width = original[kCGImagePropertyPixelWidth as String] as? NSNumber,
                  let height = original[kCGImagePropertyPixelHeight as String] as? NSNumber,
                  width.intValue > 0, height.intValue > 0 else {
                throw StampError.encodingFailed
            }
            // Decode the full image and bake EXIF rotation/mirroring into its pixels.
            // Never use the embedded thumbnail or reduce the capture's dimensions.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width.intValue, height.intValue)
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw StampError.encodingFailed
            }
            let size = CGSize(width: image.width, height: image.height)
            let shortEdge = min(size.width, size.height)
            let margin = shortEdge * 0.025
            let font = UIFont.monospacedDigitSystemFont(ofSize: shortEdge * 0.032, weight: .medium)
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.85)
            shadow.shadowOffset = CGSize(width: 0, height: shortEdge * 0.001)
            shadow.shadowBlurRadius = shortEdge * 0.003
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: UIColor.white, .shadow: shadow
            ]
            let label = text as NSString
            let textSize = label.size(withAttributes: attributes)
            let rect = CGRect(x: size.width - margin - textSize.width,
                              y: size.height - margin - textSize.height,
                              width: textSize.width, height: textSize.height)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            format.preferredRange = .standard
            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
                label.draw(in: rect, withAttributes: attributes)
            }
            guard let outputImage = rendered.cgImage else { throw StampError.encodingFailed }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, UTType.heic.identifier as CFString, 1, nil
            ) else { throw StampError.encodingFailed }

            // Retain capture metadata, but remove structures tied to the original pixels.
            var properties: [String: Any] = [:]
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary,
                        kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
                properties[key as String] = original[key as String]
            }
            properties[kCGImagePropertyOrientation as String] = 1
            properties[kCGImagePropertyPixelWidth as String] = outputImage.width
            properties[kCGImagePropertyPixelHeight as String] = outputImage.height
            properties[kCGImageDestinationLossyCompressionQuality as String] = 1.0
            var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            exif[kCGImagePropertyExifPixelXDimension as String] = outputImage.width
            exif[kCGImagePropertyExifPixelYDimension as String] = outputImage.height
            exif.removeValue(forKey: kCGImagePropertyExifMakerNote as String)
            properties[kCGImagePropertyExifDictionary as String] = exif
            var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
            CGImageDestinationAddImage(destination, outputImage, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination),
                  let verification = CGImageSourceCreateWithData(output as CFData, nil),
                  CGImageSourceGetType(verification) as String? == UTType.heic.identifier else {
                throw StampError.encodingFailed
            }
            return output as Data
        }
    }

    private enum StampError: LocalizedError {
        case encodingFailed
        var errorDescription: String? {
            "The photo date and time stamp could not be saved. Please try taking the photo again."
        }
    }
}
