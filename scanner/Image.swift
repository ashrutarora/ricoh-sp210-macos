// Levels, scaling and file formats for scans.
// SPDX-License-Identifier: GPL-2.0-or-later

import Accelerate
import CoreGraphics
import Foundation
import ImageIO

private func levelsTable(white: Int, black: Int = blackLevel) -> [UInt8] {
    (0..<256).map { v in
        let level = (Double((v - black) * 255) / Double(white - black)).rounded(.toNearestOrEven)
        return UInt8(min(255, max(0, level)))
    }
}

/// White and black levels, so paper comes out white and ink black.
func applyLevels(_ image: inout Raster) {
    let tables = image.channels == 1 ? [levelsTable(white: whiteGrey)] : whiteRGB.map { levelsTable(white: $0) }
    let channels = image.channels
    image.pixels.withUnsafeMutableBufferPointer { p in
        for c in 0..<channels {
            let table = tables[c]
            var i = c
            while i < p.count {
                p[i] = table[Int(p[i])]
                i += channels
            }
        }
    }
}

/// High-quality (Lanczos) resampling to a new size.
func scaled(_ image: Raster, width: Int, height: Int) -> Raster {
    var source = image.pixels
    if image.channels == 1 {
        var out = [UInt8](repeating: 0, count: width * height)
        source.withUnsafeMutableBytes { s in
            out.withUnsafeMutableBytes { d in
                var src = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(image.height),
                                        width: vImagePixelCount(image.width), rowBytes: image.width)
                var dst = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(height),
                                        width: vImagePixelCount(width), rowBytes: width)
                _ = vImageScale_Planar8(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        return Raster(width: width, height: height, channels: 1, pixels: out)
    }
    // vImage scales 4-channel pixels; go through ARGB and back.
    var argb = [UInt8](repeating: 0, count: image.width * image.height * 4)
    var argbOut = [UInt8](repeating: 0, count: width * height * 4)
    var out = [UInt8](repeating: 0, count: width * height * 3)
    source.withUnsafeMutableBytes { s in
        argb.withUnsafeMutableBytes { a in
            argbOut.withUnsafeMutableBytes { b in
                out.withUnsafeMutableBytes { d in
                    var rgb = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(image.height),
                                            width: vImagePixelCount(image.width), rowBytes: image.width * 3)
                    var big = vImage_Buffer(data: a.baseAddress, height: vImagePixelCount(image.height),
                                            width: vImagePixelCount(image.width), rowBytes: image.width * 4)
                    var small = vImage_Buffer(data: b.baseAddress, height: vImagePixelCount(height),
                                              width: vImagePixelCount(width), rowBytes: width * 4)
                    var result = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(height),
                                               width: vImagePixelCount(width), rowBytes: width * 3)
                    let none = vImage_Flags(kvImageNoFlags)
                    _ = vImageConvert_RGB888toARGB8888(&rgb, nil, 255, &big, false, none)
                    _ = vImageScale_ARGB8888(&big, &small, nil, vImage_Flags(kvImageHighQualityResampling))
                    _ = vImageConvert_ARGB8888toRGB888(&small, &result, none)
                }
            }
        }
    }
    return Raster(width: width, height: height, channels: 3, pixels: out)
}

func cgImage(_ image: Raster) -> CGImage? {
    let space = image.channels == 1 ? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)
                                    : CGColorSpace(name: CGColorSpace.sRGB)
    guard let space, let provider = CGDataProvider(data: Data(image.pixels) as CFData) else { return nil }
    return CGImage(width: image.width, height: image.height, bitsPerComponent: 8,
                   bitsPerPixel: 8 * image.channels, bytesPerRow: image.width * image.channels,
                   space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

/// The scan as a PNG, JPEG or PDF file (by MIME type), tagged with its resolution.
func encode(_ image: Raster, format: String, dpi: Int) throws -> Data {
    guard let picture = cgImage(image) else { throw ScannerError("cannot build the image") }
    let out = NSMutableData()
    if format == "application/pdf" {
        var page = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / Double(dpi),
                          height: Double(image.height) * 72 / Double(dpi))
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: &page, nil) else {
            throw ScannerError("cannot write PDF")
        }
        pdf.beginPDFPage(nil)
        pdf.draw(picture, in: page)
        pdf.endPDFPage()
        pdf.closePDF()
        return out as Data
    }
    let type = format == "image/jpeg" ? "public.jpeg" : "public.png"
    guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, type as CFString, 1, nil) else {
        throw ScannerError("cannot write \(format)")
    }
    var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
    if format == "image/jpeg" { properties[kCGImageDestinationLossyCompressionQuality] = 0.9 }
    CGImageDestinationAddImage(destination, picture, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw ScannerError("cannot write \(format)") }
    return out as Data
}
