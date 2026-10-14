// Checks for the image side of the scanner service, on a made-up scan (no printer needed).
// Built and run by scanner/test_image.sh.
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import ImageIO

func log(_ message: String) {}

var failed = false
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "ok   \(name)" : "FAIL \(name) \(detail)")
    if !ok { failed = true }
}

// A raw 300 dpi colour scan of an A4 page: paper (193, 184, 205) with a band of ink, plus sensor noise.
let w = 2536, h = 3496
var rng = SystemRandomNumberGenerator()
var pixels = [UInt8](repeating: 0, count: w * h * 3)
for y in 0..<h {
    for x in 0..<w {
        let i = (y * w + x) * 3
        let ink = y > 1000 && y < 1400 && x < 1800
        let noise = Int.random(in: -6...6, using: &rng)
        pixels[i] = UInt8(clamping: (ink ? 20 : 193) + noise)
        pixels[i + 1] = UInt8(clamping: (ink ? 20 : 184) + noise)
        pixels[i + 2] = UInt8(clamping: (ink ? 20 : 205) + noise)
    }
}
var page = Raster(width: w, height: h, channels: 3, pixels: pixels)
applyLevels(&page)
let paper = page.pixels[0..<3].map(Int.init)
check("levels: paper comes out near white", paper.allSatisfy { $0 >= 230 }, "\(paper)")
let inkAt = (1200 * w + 100) * 3
check("levels: ink comes out black", page.pixels[inkAt] == 0, "\(page.pixels[inkAt])")

let small = scaled(page, width: 634, height: 874)
check("scaling to 75 dpi", small.width == 634 && small.height == 874 && small.pixels.count == 634 * 874 * 3)

for (format, type) in [("image/png", "public.png"), ("image/jpeg", "public.jpeg")] {
    let data = try encode(small, format: format, dpi: 75)
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    check("\(format): type and 75 dpi tag", CGImageSourceGetType(source) as String? == type
          && (props[kCGImagePropertyDPIWidth] as? Double) == 75)
}

// A full page as PDF must stay small: the picture goes in as JPEG, as in version 1.0, not raw.
let pdf = try encode(page, format: "application/pdf", dpi: 300)
let text = String(decoding: pdf, as: UTF8.self)
check("PDF: picture stored as JPEG (DCTDecode)", text.contains("/DCTDecode"))
check("PDF: full colour page under 3 MB", pdf.count < 3_000_000, "\(pdf.count) bytes")
let document = CGPDFDocument(CGDataProvider(data: pdf as CFData)!)!
let box = document.page(at: 1)!.getBoxRect(.mediaBox)
check("PDF: page is 2536x3496 px at 300 dpi in points",
      abs(box.width - 2536 * 72 / 300.0) < 0.01 && abs(box.height - 3496 * 72 / 300.0) < 0.01, "\(box)")
var grey = Raster(width: 1268, height: 1748, channels: 1, pixels: [UInt8](repeating: 195, count: 1268 * 1748))
applyLevels(&grey)
let greyPDF = try encode(grey, format: "application/pdf", dpi: 150)
check("PDF: greyscale page works", String(decoding: greyPDF, as: UTF8.self).contains("/DCTDecode"))
exit(failed ? 1 : 0)
