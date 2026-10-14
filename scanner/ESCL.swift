// AirScan (eSCL): the scanner's description, scan settings, jobs and the HTTP routes.
// SPDX-License-Identifier: GPL-2.0-or-later

import CExpat
import Foundation

let namespaces = "xmlns:pwg='http://www.pwg.org/schemas/2010/12/sm' " +
                 "xmlns:scan='http://schemas.hp.com/imaging/escl/2011/05/03'"
let scannerUUID = "dc07a7b5-4851-551e-8a73-d4070bccaf0f"  // uuid5(URL, "ricoh-sp210su-escl"), kept from 1.0
let bonjourHost = "ricoh-sp210su-scanner.local"
let localHosts: Set<String> = ["127.0.0.1", "localhost", "[::1]", bonjourHost, bonjourHost + "."]
let formats = ["application/pdf", "image/jpeg", "image/png"]
// Offered to Mac apps. 1200 dpi works but a full page takes over 10 minutes, long enough for apps
// to give up waiting, so it stays out of this list (the scan command still does it).
let escleResolutions = resolutions.filter { $0 <= 600 }
let maxWidth = glassWidth - edge, maxHeight = glassHeight - edge

func capabilitiesXML(name: String) -> String {
    let res = escleResolutions.map {
        "<scan:DiscreteResolution><scan:XResolution>\($0)</scan:XResolution>" +
        "<scan:YResolution>\($0)</scan:YResolution></scan:DiscreteResolution>"
    }.joined()
    let docs = formats.map { "<pwg:DocumentFormat>\($0)</pwg:DocumentFormat>" }.joined()
    let intents = ["Document", "TextAndGraphic", "Photo", "Preview"].map {
        "<scan:SupportedIntent>\($0)</scan:SupportedIntent>"
    }.joined()
    return """
    <?xml version='1.0' encoding='UTF-8'?>
    <scan:ScannerCapabilities \(namespaces)>
    <pwg:Version>2.0</pwg:Version>
    <pwg:MakeAndModel>\(xmlEscaped(name))</pwg:MakeAndModel>
    <pwg:SerialNumber>1</pwg:SerialNumber>
    <scan:UUID>\(scannerUUID)</scan:UUID>
    <scan:Platen><scan:PlatenInputCaps>
    <scan:MinWidth>16</scan:MinWidth><scan:MaxWidth>\(maxWidth)</scan:MaxWidth>
    <scan:MinHeight>16</scan:MinHeight><scan:MaxHeight>\(maxHeight)</scan:MaxHeight>
    <scan:MaxPhysicalWidth>\(maxWidth)</scan:MaxPhysicalWidth>
    <scan:MaxPhysicalHeight>\(maxHeight)</scan:MaxPhysicalHeight>
    <scan:MaxScanRegions>1</scan:MaxScanRegions>
    <scan:SettingProfiles><scan:SettingProfile>
    <scan:ColorModes><scan:ColorMode>Grayscale8</scan:ColorMode><scan:ColorMode>RGB24</scan:ColorMode></scan:ColorModes>
    <scan:ColorSpaces><scan:ColorSpace>sRGB</scan:ColorSpace></scan:ColorSpaces>
    <scan:SupportedResolutions><scan:DiscreteResolutions>\(res)</scan:DiscreteResolutions></scan:SupportedResolutions>
    <scan:DocumentFormats>\(docs)</scan:DocumentFormats>
    </scan:SettingProfile></scan:SettingProfiles>
    <scan:SupportedIntents>\(intents)</scan:SupportedIntents>
    </scan:PlatenInputCaps></scan:Platen>
    </scan:ScannerCapabilities>

    """
}

func xmlEscaped(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

struct BadRequest: Error {}

/// Reads a ScanSettings document into {local element name: text}, first element wins. Scan
/// settings never need a DTD, so one is refused; expat reads the declared encoding, so this also
/// catches a DTD in UTF-16, which a byte search would miss. That rules out entity-expansion
/// tricks.
final class SettingsReader {
    private var values: [String: String] = [:]
    private var stack: [(name: String, text: String, hasChild: Bool)] = []
    private var refused = false
    private var parser: XML_Parser?

    static func read(_ data: Data) throws -> [String: String] {
        let reader = SettingsReader()
        guard let parser = XML_ParserCreate(nil) else { throw BadRequest() }
        defer { XML_ParserFree(parser) }
        reader.parser = parser
        XML_SetUserData(parser, Unmanaged.passUnretained(reader).toOpaque())
        XML_SetElementHandler(parser, { user, name, _ in
            let r = SettingsReader.from(user)
            if !r.stack.isEmpty { r.stack[r.stack.count - 1].hasChild = true }
            let full = String(cString: name!)
            r.stack.append((String(full.split(separator: ":").last ?? ""), "", false))
        }, { user, _ in
            let r = SettingsReader.from(user)
            guard let element = r.stack.popLast() else { return }
            let text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && r.values[element.name] == nil { r.values[element.name] = text }
        })
        XML_SetCharacterDataHandler(parser, { user, chars, length in
            let r = SettingsReader.from(user)
            guard !r.stack.isEmpty, !r.stack[r.stack.count - 1].hasChild, let chars else { return }
            let bytes = UnsafeRawBufferPointer(start: chars, count: Int(length))
            r.stack[r.stack.count - 1].text += String(decoding: bytes, as: UTF8.self)
        })
        XML_SetStartDoctypeDeclHandler(parser, { user, _, _, _, _ in SettingsReader.from(user).refuse() })
        XML_SetEntityDeclHandler(parser, { user, _, _, _, _, _, _, _, _ in SettingsReader.from(user).refuse() })
        let ok = data.withUnsafeBytes { p in
            XML_Parse(parser, p.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(data.count), 1)
        }
        if reader.refused || ok != XML_STATUS_OK { throw BadRequest() }
        return reader.values
    }

    private static func from(_ user: UnsafeMutableRawPointer?) -> SettingsReader {
        Unmanaged<SettingsReader>.fromOpaque(user!).takeUnretainedValue()
    }

    private func refuse() {
        refused = true
        XML_StopParser(parser, XML_FALSE)
    }
}

final class Job {
    let id = UUID().uuidString.lowercased()
    let created = Date()
    let dpi: Int
    let colour: Bool
    let x, y, width, height: Int
    let format: String
    var state = "Pending"            // Pending, Processing, Completed, Canceled, Aborted
    var done = false

    init(settings data: Data, fromAirScan: Bool) throws {
        let s = try SettingsReader.read(data)
        func number(_ key: String, _ fallback: Int) throws -> Double {
            guard let text = s[key] else { return Double(fallback) }
            guard let value = Double(text), value.isFinite, abs(value) < 1e6 else { throw BadRequest() }
            return value.rounded(.towardZero)
        }
        let asked = Int(try number("XResolution", 300))
        dpi = escleResolutions.min { abs($0 - asked) < abs($1 - asked) }!
        colour = (s["ColorMode"] ?? "RGB24").hasPrefix("RGB")
        let units = s["ContentRegionUnits"] ?? "escl:ThreeHundredthsOfInches"
        let k = units.hasSuffix("ThreeHundredthsOfInches") ? 1 : 300 / Double(dpi)
        x = Int((try number("XOffset", 0) * k).rounded(.toNearestOrEven))
        y = Int((try number("YOffset", 0) * k).rounded(.toNearestOrEven))
        width = Int((try number("Width", maxWidth) * k).rounded(.toNearestOrEven))
        height = Int((try number("Height", maxHeight) * k).rounded(.toNearestOrEven))
        var format = s["DocumentFormatExt"] ?? s["DocumentFormat"] ?? "image/jpeg"
        if fromAirScan && format == "image/jpeg" {
            format = "image/png"          // lossless for Apple's client, as AirSane does
        }
        self.format = formats.contains(format) ? format : "image/png"
    }

    var infoXML: String {
        "<scan:JobInfo><pwg:JobUri>/eSCL/ScanJobs/\(id)</pwg:JobUri>" +
        "<pwg:JobUuid>\(id)</pwg:JobUuid><scan:Age>\(Int(Date().timeIntervalSince(created)))</scan:Age>" +
        "<pwg:ImagesCompleted>\(done ? 1 : 0)</pwg:ImagesCompleted>" +
        "<pwg:ImagesToTransfer>\(done ? 0 : 1)</pwg:ImagesToTransfer>" +
        "<pwg:JobState>\(state)</pwg:JobState></scan:JobInfo>"
    }
}

let maxJobs = 20

final class Service {
    let name: String
    private var jobs: [Job] = []          // oldest first
    private let lock = NSLock()           // guards jobs, busy and job fields
    private let scanLock = NSLock()       // one scan at a time
    private var busy = false

    init(name: String) { self.name = name }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func job(_ id: String) -> Job? { jobs.first { $0.id == id } }

    var statusXML: String {
        locked {
            let list = jobs.suffix(10).map(\.infoXML).joined()
            return "<?xml version='1.0' encoding='UTF-8'?>\n<scan:ScannerStatus \(namespaces)>" +
                   "<pwg:Version>2.0</pwg:Version><pwg:State>\(busy ? "Processing" : "Idle")</pwg:State>" +
                   "<scan:Jobs>\(list)</scan:Jobs></scan:ScannerStatus>\n"
        }
    }

    /// Scans for a job; nil if the job is unknown or already finished.
    private func run(_ id: String) throws -> (Data, String)? {
        scanLock.lock()
        defer { scanLock.unlock() }
        guard let job = locked({ () -> Job? in
            guard let job = job(id), !job.done else { return nil }
            busy = true
            job.state = "Processing"
            return job
        }) else { return nil }
        let start = Date()
        do {
            let scanner = try Scanner()
            defer { scanner.close() }
            let image = try scanner.scan(colour: job.colour, dpi: job.dpi, x: job.x, y: job.y,
                                         width: job.width, height: job.height)
            let data = try encode(image, format: job.format, dpi: job.dpi)
            log("scanned \(image.width)x\(image.height) \(job.colour ? "colour" : "grey") \(job.dpi) dpi " +
                "\(job.format) \(data.count) bytes in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
            locked { job.state = "Completed"; job.done = true; busy = false }
            return (data, job.format)
        } catch {
            locked { job.state = "Aborted"; job.done = true; busy = false }
            throw error
        }
    }

    /// Only scanning apps on this Mac, never a web page. Pages always send Origin on cross-site
    /// requests, and a DNS-rebinding page arrives with its own host name.
    private func fromLocalApp(_ r: Request) -> Bool {
        let host = (r.header("host") ?? "").lowercased()
        var name = host
        if !host.hasSuffix("]"), let colon = host.lastIndex(of: ":") { name = String(host[..<colon]) }
        if localHosts.contains(name) && r.header("origin") == nil { return true }
        log("refused \(r.method) \(r.path): Host \(host.debugDescription), Origin \((r.header("origin") ?? "none").debugDescription)")
        return false
    }

    func handle(_ r: Request) -> Response {
        guard fromLocalApp(r) else { return Response(403) }
        let parts = r.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        switch r.method {
        case "GET":
            if r.path == "/eSCL/ScannerCapabilities" { return Response(200, capabilitiesXML(name: name)) }
            if r.path == "/eSCL/ScannerStatus" { return Response(200, statusXML, quiet: true) }
            if parts.count == 4 && parts[0] == "eSCL" && parts[1] == "ScanJobs" && parts[3] == "NextDocument" {
                do {
                    guard let (data, type) = try run(parts[2]) else { return Response(404) }
                    return Response(200, data, type: type)
                } catch let e as ScannerError {
                    log("scan failed: \(e)")
                    return Response(503)
                } catch {
                    log("scan failed: \(error)")
                    return Response(500)
                }
            }
            return Response(404)
        case "POST":
            guard r.path == "/eSCL/ScanJobs" else { return Response(404) }
            let job: Job
            do {
                job = try Job(settings: r.body, fromAirScan: (r.header("user-agent") ?? "").contains("AirScanScanner"))
            } catch {
                return Response(400)
            }
            let added = locked { () -> Bool in
                if busy { return false }
                jobs.append(job)
                if jobs.count > maxJobs { jobs.removeFirst(jobs.count - maxJobs) }
                return true
            }
            guard added else { return Response(503) }
            log("job \(job.id.prefix(8)): \(job.colour ? "colour" : "grey") \(job.dpi) dpi, " +
                "area \(job.x),\(job.y) \(job.width)x\(job.height)/300 in, \(job.format)")
            return Response(201, headers: [("Location", "/eSCL/ScanJobs/\(job.id)")])
        case "DELETE":
            let found = locked { () -> Bool in
                guard parts.count == 3, let job = job(parts[2]) else { return false }
                if !job.done { job.state = "Canceled"; job.done = true }
                return true
            }
            return Response(found ? 200 : 404)
        default:
            return Response(501)
        }
    }
}
