// ricoh-sp210-scanner: the Ricoh SP 210SU's scanner on macOS.
//
//   ricoh-sp210-scanner serve [--port 8090] [--name "Ricoh SP 210SU"] [--log]
//       AirScan (eSCL) service, so Image Capture, Preview (File > Import from Scanner) and
//       System Settings > Printers & Scanners list the scanner. It listens on 127.0.0.1 only and
//       Bonjour announces it to this Mac only, so nobody else on the network sees it or can scan
//       from your glass. Requests from web pages (Origin header, or a foreign Host name from DNS
//       rebinding) are refused too. --log writes to ~/Library/Logs/RicohSP210Scanner.log.
//   ricoh-sp210-scanner status
//       Asks the scanner whether it is ready; a quick check that it can be reached over USB.
//   ricoh-sp210-scanner scan [--grey] [--dpi 300] [--area x,y,width,height] FILE.png|.jpg|.pdf
//       One scan from the command line; area in 1/300 inch. Also does 1200 dpi.
//
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

let logLock = NSLock()
let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

func log(_ message: String) {
    logLock.withLock {
        FileHandle.standardError.write(Data("\(clock.string(from: Date())) \(message)\n".utf8))
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ricoh-sp210-scanner: \(message)\n".utf8))
    exit(1)
}

/// Sends stderr to the log file, starting a new one when it passes 1 MB.
func logToFile() {
    let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let file = logs.appendingPathComponent("RicohSP210Scanner.log")
    if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size > 1 << 20 {
        let old = logs.appendingPathComponent("RicohSP210Scanner.old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: file, to: old)
    }
    let fd = open(file.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    if fd >= 0 {
        dup2(fd, STDERR_FILENO)
        close(fd)
    }
}

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value") }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

let usage = """
usage: ricoh-sp210-scanner serve [--port 8090] [--name NAME] [--log]
       ricoh-sp210-scanner status
       ricoh-sp210-scanner scan [--grey] [--dpi 300] [--area x,y,width,height] FILE.png|.jpg|.pdf
"""

switch args.first {
case "serve":
    args.removeFirst()
    let port = option("--port").map { UInt16($0) ?? 0 } ?? 8090
    let name = option("--name") ?? "Ricoh SP 210SU"
    if flag("--log") { logToFile() }
    guard args.isEmpty, port > 0 else { fail(usage) }
    // launchd stops the service with SIGTERM; exit cleanly so the announcement goes at once.
    signal(SIGTERM) { _ in exit(0) }
    let service = Service(name: name)
    do {
        let server = try HTTPServer(port: port, handler: service.handle)
        server.start()
        try announce(name: name, port: port)
    } catch {
        log("\(error)")
        exit(1)
    }
    log("AirScan service for \(name) on http://127.0.0.1:\(port)/eSCL")
    dispatchMain()

case "status":
    do {
        let scanner = try Scanner()
        defer { scanner.close() }
        let reply = try scanner.status()
        print(reply.first == 1 ? "ready" : "busy (\(reply.map { String($0) }.joined(separator: " ")))")
    } catch {
        fail("\(error)")
    }

case "scan":
    args.removeFirst()
    let colour = !flag("--grey")
    let dpi = option("--dpi").map { Int($0) ?? 0 } ?? 300
    let area = option("--area")?.split(separator: ",").compactMap { Int($0) }
    guard args.count == 1, resolutions.contains(dpi), area == nil || area!.count == 4 else {
        fail("\(usage)\n(dpi is one of \(resolutions.map(String.init).joined(separator: ", ")))")
    }
    let path = args[0]
    let ext = (path as NSString).pathExtension.lowercased()
    let format = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "pdf": "application/pdf"][ext]
    guard let format else { fail("FILE must end in .png, .jpg or .pdf") }
    do {
        let scanner = try Scanner()
        defer { scanner.close() }
        var last = -1
        let image = try scanner.scan(colour: colour, dpi: dpi, x: area?[0] ?? 0, y: area?[1] ?? 0,
                                     width: area?[2], height: area?[3]) { done, total in
            let percent = done * 100 / total
            if percent / 10 != last / 10 {
                FileHandle.standardError.write(Data("\(percent)%\n".utf8))
            }
            last = percent
        }
        try encode(image, format: format, dpi: dpi).write(to: URL(fileURLWithPath: path))
        print("\(path): \(image.width)x\(image.height) at \(dpi) dpi")
    } catch {
        fail("\(error)")
    }

default:
    fail(usage)
}
