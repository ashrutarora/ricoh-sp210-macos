// Draws the disk image's window background: the installer icon's panel on the left and the steps
// on the right. Writes background.png and background@2x.png into the folder given.
//   swift pkg/make-background.swift out/pkg
// The icon sits on a mid-tone panel because Finder labels it in black in Light Mode and in white
// in Dark Mode; both read on that panel.
// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

// The bottom 24 points stay plain: Finder windows with the tab bar showing are that much shorter.
let width = 760.0, height = 504.0
let panel = NSRect(x: 24, y: 24, width: 236, height: 432)   // must match pkg/dmg-settings.py
let ink = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)
let soft = NSColor(srgbRed: 0.36, green: 0.39, blue: 0.44, alpha: 1)
let accent = NSColor(srgbRed: 0.13, green: 0.32, blue: 0.75, alpha: 1)

func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    .systemFont(ofSize: size, weight: weight)
}

/// Draws text with its top at y (measured from the top of the window); returns the bottom.
@discardableResult
func text(_ s: String, x: Double, y: Double, width: Double, size: CGFloat, weight: NSFont.Weight = .regular,
          color: NSColor = ink, lineHeight: CGFloat = 1.3) -> Double {
    let style = NSMutableParagraphStyle()
    style.lineHeightMultiple = lineHeight
    let string = NSAttributedString(string: s, attributes: [.font: font(size, weight), .foregroundColor: color,
                                                            .paragraphStyle: style])
    let bounds = string.boundingRect(with: NSSize(width: width, height: 1000),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading])
    let h = ceil(bounds.height)
    string.draw(with: NSRect(x: x, y: height - y - h, width: width, height: h),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
    return y + h
}

/// Rich text: **bold** spans in a plain string.
func rich(_ s: String, x: Double, y: Double, width: Double, size: CGFloat) -> Double {
    let style = NSMutableParagraphStyle()
    style.lineHeightMultiple = 1.3
    let out = NSMutableAttributedString()
    for (i, part) in s.components(separatedBy: "**").enumerated() {
        out.append(NSAttributedString(string: part, attributes: [
            .font: font(size, i % 2 == 1 ? .semibold : .regular), .foregroundColor: ink, .paragraphStyle: style]))
    }
    let bounds = out.boundingRect(with: NSSize(width: width, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading])
    let h = ceil(bounds.height)
    out.draw(with: NSRect(x: x, y: height - y - h, width: width, height: h), options: [.usesLineFragmentOrigin, .usesFontLeading])
    return y + h
}

func step(_ n: Int, x: Double, y: Double) {
    let r = 13.0
    let circle = NSBezierPath(ovalIn: NSRect(x: x, y: height - y - 2 * r, width: 2 * r, height: 2 * r))
    accent.setFill()
    circle.fill()
    let label = NSAttributedString(string: "\(n)", attributes: [.font: font(14, .bold), .foregroundColor: NSColor.white])
    let size = label.size()
    label.draw(at: NSPoint(x: x + r - size.width / 2, y: height - y - r - size.height / 2))
}

/// A small picture of the "Open Anyway" button, so people recognise it in System Settings.
func button(_ title: String, x: Double, y: Double) {
    let label = NSAttributedString(string: title, attributes: [.font: font(12, .regular), .foregroundColor: ink])
    let size = label.size()
    let rect = NSRect(x: x, y: height - y - 22, width: size.width + 24, height: 22)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
    NSColor.white.setFill()
    shape.fill()
    NSColor(white: 0, alpha: 0.18).setStroke()
    shape.lineWidth = 1
    shape.stroke()
    label.draw(at: NSPoint(x: x + 12, y: rect.midY - size.height / 2))
}

func draw() {
    NSColor(srgbRed: 0.965, green: 0.969, blue: 0.976, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    // Left: the panel the two icons sit on (positions in pkg/dmg-settings.py).
    let card = NSRect(x: panel.minX, y: height - panel.maxY, width: panel.width, height: panel.height)
    NSColor(srgbRed: 0.43, green: 0.50, blue: 0.59, alpha: 1).setFill()
    NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14).fill()
    let white = NSColor.white
    text("Start here", x: panel.minX + 20, y: panel.minY + 20, width: panel.width - 40, size: 20, weight: .bold, color: white)
    step(1, x: panel.minX + 16, y: 92)
    // A thin rule between the two icons.
    white.withAlphaComponent(0.35).setFill()
    NSRect(x: panel.minX + 20, y: height - 258, width: panel.width - 40, height: 1).fill()
    text("If macOS blocks it:", x: panel.minX + 20, y: 268, width: panel.width - 40, size: 13, weight: .semibold, color: white)
    step(2, x: panel.minX + 16, y: 296)

    // Right: the steps.
    let x = 296.0, w = width - x - 36
    var y = 34.0
    y = text("Ricoh SP 210SU driver for Mac", x: x, y: y, width: w, size: 22, weight: .bold)
    y = text("Print from any app and scan with Image Capture or Preview.", x: x, y: y + 2, width: w, size: 13, color: soft)
    let tx = x + 40, tw = w - 40

    y += 26
    step(1, x: x, y: y + 1)
    y = rich("Double-click **Install Ricoh SP 210SU** on the left.", x: tx, y: y, width: tw, size: 14)

    y += 20
    step(2, x: x, y: y + 1)
    y = rich("If macOS says it **could not verify** the installer, click **Done** (or **OK**). Then double-click " +
             "**Open Privacy & Security** on the left and, next to the installer's name, click:", x: tx, y: y, width: tw, size: 14)
    button("Open Anyway", x: tx, y: y + 8)
    y += 38
    y = text("Confirm with your Mac password, and click Open Anyway again if macOS asks. It asks because this " +
             "free installer is not registered with Apple.", x: tx, y: y, width: tw, size: 12, color: soft)

    y += 20
    step(3, x: x, y: y + 1)
    y = rich("Follow the installer. Then connect the printer by USB and switch it on.", x: tx, y: y, width: tw, size: 14)

    text("To print: File › Print, and choose Ricoh SP 210SU.\nTo scan: open Image Capture, or Preview › File › Import from Scanner.\n" +
         "Free and open source: github.com/ashrutarora/ricoh-sp210-macos",
         x: x, y: 396, width: w, size: 12, color: soft)
}

func render(scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let folder = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
render(scale: 1, to: "\(folder)/background.png")
render(scale: 2, to: "\(folder)/background@2x.png")
