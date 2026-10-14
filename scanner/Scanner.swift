// Scanner side of the Ricoh SP 210SU over USB (interface 1, bulk endpoints 0x02 out, 0x82 in).
//
// Commands are 4-byte little-endian numbers on the OUT endpoint; replies and image data come back
// on the IN endpoint. Worked out from Ricoh's Windows scanner driver for interoperability; see
// SCANNER.md.
//
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import IOKit
import IOUSBHost

let vendorID = 0x05CA, productID = 0x044F
let scannerInterface = 1, endpointOut = 0x02, endpointIn = 0x82

enum Command: UInt32 {
    case status = 1, setParameters = 3, start = 4, stop = 5, gamma = 9, cancel = 0x0C
    case driverClose = 0x0D, finish = 0x1E, unlock = 0x24, wake = 0x32
}

let hardwareDPI = [300, 600, 1200]                 // the scanner ignores lower values and scans at 300
let resolutions = [75, 100, 150, 200, 300, 600, 1200]  // below 300: scanned at 300, scaled down
// 1200 dpi is slow: about 30 s per square inch, so over 10 minutes for a full page.
let glassWidth = 2546                              // 1/300 inch: 215.5 mm
let glassHeight = 3508                             // 1/300 inch: 297 mm (A4)
let edge = 10                                      // 1/300 inch of dark glass edge at the top and left, skipped

// Raw readings: ink about 20; white paper about 195 in grey, and red 198, green 189, blue 210 in
// colour. Levels stretch black..white to 0..255 per channel, so paper comes out white.
let blackLevel = 30
let whiteGrey = 190
let whiteRGB = [193, 184, 205]

// The scanner accepts a tone curve (1024 entries per channel) but does not appear to apply it, so
// a straight one is sent, as Ricoh's driver does, and the levels do the work.
let linearCurve = Data((0..<3).flatMap { _ in (0..<1024).map { UInt8($0 >> 2) } })

struct ScannerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// 8-bit grey (1 channel) or RGB (3 channels) pixels, top to bottom, no padding.
struct Raster {
    var width: Int
    var height: Int
    var channels: Int
    var pixels: [UInt8]
}

final class Scanner {
    private let interface: IOUSBHostInterface
    private let pipeOut: IOUSBHostPipe
    private let pipeIn: IOUSBHostPipe

    init() throws {
        guard let match = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary? else {
            throw ScannerError("IOKit matching failed")
        }
        // The USB family only takes certain key combinations at the top level (and this one needs
        // bConfigurationValue too); IOPropertyMatch compares the properties as they are.
        match["IOPropertyMatch"] = ["idVendor": vendorID, "idProduct": productID,
                                    "bInterfaceNumber": scannerInterface]
        let service = IOServiceGetMatchingService(mach_port_t(MACH_PORT_NULL), match)
        guard service != 0 else { throw ScannerError("Ricoh SP 210SU not found on USB") }
        defer { IOObjectRelease(service) }
        do {
            interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil,
                                               interestHandler: nil)
        } catch {
            throw ScannerError("cannot open the scanner (\(error.localizedDescription))")
        }
        do {
            pipeOut = try interface.copyPipe(withAddress: endpointOut)
            pipeIn = try interface.copyPipe(withAddress: endpointIn)
        } catch {
            interface.destroy()
            throw ScannerError("scanner endpoints missing (\(error.localizedDescription))")
        }
    }

    func close() {
        interface.destroy()
    }

    private func write(_ data: Data) throws {
        let buffer = NSMutableData(data: data)
        var sent = 0
        try pipeOut.__sendIORequest(with: buffer, bytesTransferred: &sent, completionTimeout: 5)
    }

    private func command(_ c: Command, _ extra: Data = Data()) throws {
        var n = c.rawValue.littleEndian
        try write(Data(bytes: &n, count: 4) + extra)
    }

    /// Up to `size` bytes, or nil when nothing arrives within `timeout` seconds.
    private func read(_ size: Int, timeout: TimeInterval) throws -> Data? {
        let buffer = NSMutableData(length: size)!
        var got = 0
        do {
            try pipeIn.__sendIORequest(with: buffer, bytesTransferred: &got, completionTimeout: timeout)
        } catch let e as NSError {
            let timedOut = Int32(truncatingIfNeeded: e.code) == Int32(bitPattern: 0xE000_02D6)  // kIOReturnTimeout
            let aborted = Int32(truncatingIfNeeded: e.code) == Int32(bitPattern: 0xE000_02EB)   // kIOReturnAborted
            if timedOut || aborted { return nil }
            throw e
        }
        return Data(bytes: buffer.bytes, count: got)
    }

    /// 8 status bytes; byte 0 is 1 when the scanner is ready.
    @discardableResult
    func status() throws -> Data {
        try command(.status)
        guard let reply = try read(512, timeout: 5) else {
            throw ScannerError("scanner did not answer a status request")
        }
        return reply
    }

    /// Scan an area of the glass at `dpi`, levelled so paper is white. x, y, width and height
    /// are in 1/300 inch from the top left corner; width and height default to the rest of the
    /// glass.
    func scan(colour: Bool, dpi: Int, x: Int = 0, y: Int = 0, width: Int? = nil, height: Int? = nil,
              progress: ((Int, Int) -> Void)? = nil) throws -> Raster {
        precondition(resolutions.contains(dpi), "dpi must be one of \(resolutions)")
        let x = max(0, x), y = max(0, y)
        let width = min(width ?? glassWidth, glassWidth - edge - x)
        let height = min(height ?? glassHeight, glassHeight - edge - y)
        guard width > 0, height > 0 else { throw ScannerError("scan area is outside the glass") }
        let hw = dpi > 600 ? 1200 : dpi > 300 ? 600 : 300
        let k = hw / 300
        var image = try scanRaw(colour: colour, resolution: hw, x: (x + edge) * k, y: (y + edge) * k,
                                width: width * k, height: height * k, progress: progress)
        applyLevels(&image)
        if dpi != hw {
            image = scaled(image, width: Int((Double(image.width * dpi) / Double(hw)).rounded()),
                           height: Int((Double(image.height * dpi) / Double(hw)).rounded()))
        }
        return image
    }

    /// One scan at a hardware resolution; area in pixels at that resolution.
    private func scanRaw(colour: Bool, resolution: Int, x: Int, y: Int, width: Int, height: Int,
                         progress: ((Int, Int) -> Void)?) throws -> Raster {
        let width = width & ~7
        try status()
        try command(.wake)

        var params = [UInt8](repeating: 0, count: 32)
        func put(_ value: Int, at offset: Int, bytes: Int) {
            for i in 0..<bytes { params[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
        }
        params[0] = 1                                   // flatbed
        params[1] = 1
        params[2] = colour ? 2 : 1
        put(resolution, at: 0x04, bytes: 2)
        put(resolution, at: 0x08, bytes: 2)
        put(width, at: 0x0C, bytes: 4)
        put(height, at: 0x10, bytes: 4)
        put(x, at: 0x14, bytes: 2)
        put(y, at: 0x18, bytes: 2)
        params[0x1C] = 8                                // bits per channel
        try command(.setParameters)
        try write(Data(params))

        try command(.gamma, Data([0x00, 0x04]))
        try write(linearCurve)

        Thread.sleep(forTimeInterval: 0.5)
        try command(.start)
        let channels = colour ? 3 : 1
        let want = width * height * channels
        var data = Data(capacity: want + 8)
        do {
            defer {
                try? command(.finish)
                try? command(.stop)
                // Without these the printer's display stays on "Scanning (USB)..." after the scan.
                try? command(.driverClose)
                try? command(.unlock)
            }
            do {
                // The scanner warms its lamp first, so the first data can take several seconds.
                while data.count < want {
                    guard let chunk = try read(256 * 1024, timeout: 30) else {
                        throw ScannerError("scan stopped after \(data.count) of \(want) bytes")
                    }
                    data.append(chunk)
                    progress?(min(data.count, want), want)
                }
            } catch {
                try? command(.cancel)
                throw error
            }
        }
        if data.count - want == 8 && data.first == 1 {
            data.removeFirst(8)    // a late 8-byte status reply that arrived ahead of the image
        }
        return Raster(width: width, height: height, channels: channels, pixels: [UInt8](data.prefix(want)))
    }
}
