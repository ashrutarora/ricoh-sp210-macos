// Print from iPhone and iPad: announces this driver's print queues as AirPrint printers while they
// are shared (System Settings > General > Sharing > Printer Sharing).
//
// macOS shares the queue itself (IPP on port 631) but only announces it to iPhones when the printer
// speaks AirPrint, which a USB printer behind a driver does not. This adds the AirPrint
// announcement for the shared queue: same port and resource as macOS's own, with the "_universal"
// subtype and URF key that iPhones look for. CUPS converts what the phone sends (PDF or images)
// and prints it through this driver. The announcement follows the queue's sharing setting.
//
// SPDX-License-Identifier: GPL-2.0-or-later

import CUPS
import Foundation
import SystemConfiguration
import dnssd

struct PrintQueue: Equatable {
    var name: String          // CUPS queue name, e.g. Ricoh_SP210SU
    var info: String          // its description, e.g. "Ricoh SP 210SU (macOS driver)"
    var uuid: String
    var shared: Bool
    var onlySomeUsers: Bool   // requesting-user-name-allowed/denied is set
}

/// This driver's queues, from CUPS.
func ricohQueues() -> [PrintQueue] {
    let request = ippNewRequest(IPP_OP_CUPS_GET_PRINTERS)
    let wanted = ["printer-name", "printer-info", "printer-uuid", "printer-is-shared", "device-uri",
                  "printer-make-and-model", "requesting-user-name-allowed", "requesting-user-name-denied"]
    var cStrings = wanted.map { strdup($0) }
    defer { cStrings.forEach { free($0) } }
    cStrings.withUnsafeMutableBufferPointer { p in
        p.withMemoryRebound(to: UnsafePointer<CChar>?.self) { values in
            _ = ippAddStrings(request, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "requested-attributes",
                              Int32(values.count), nil, values.baseAddress)
        }
    }
    guard let response = cupsDoRequest(nil, request, "/") else { return [] }
    defer { ippDelete(response) }

    var queues: [PrintQueue] = []
    var current: [String: String] = [:]
    func finish() {
        defer { current = [:] }
        guard let name = current["printer-name"],
              (current["device-uri"] ?? "").hasPrefix("usb://RICOH/SP%2021"),
              (current["printer-make-and-model"] ?? "").contains("rastertoricohsp210") else { return }
        queues.append(PrintQueue(
            name: name, info: current["printer-info"] ?? name,
            uuid: (current["printer-uuid"] ?? "").replacingOccurrences(of: "urn:uuid:", with: ""),
            shared: current["printer-is-shared"] == "true",
            onlySomeUsers: current["requesting-user-name-allowed"] != nil || current["requesting-user-name-denied"] != nil))
    }
    var attr = ippFirstAttribute(response)
    while let a = attr {
        if let cname = ippGetName(a) {
            let key = String(cString: cname)
            if ippGetValueTag(a) == IPP_TAG_BOOLEAN {
                current[key] = ippGetBoolean(a, 0) != 0 ? "true" : "false"
            } else if let value = ippGetString(a, 0, nil) {
                current[key] = String(cString: value)
            }
        } else {
            finish()                    // a separator between printers
        }
        attr = ippNextAttribute(response)
    }
    finish()
    return queues
}

private func txtRecord(_ pairs: [String]) -> Data {
    var data = Data()
    for pair in pairs {
        let bytes = Array(pair.utf8.prefix(255))
        data.append(UInt8(bytes.count))
        data.append(contentsOf: bytes)
    }
    return data
}

final class AirPrint {
    private var announced: [String: (queue: PrintQueue, ref: DNSServiceRef)] = [:]
    private var warned: Set<String> = []
    private var timer: DispatchSourceTimer?

    /// Looks at the queues now and then every `interval` seconds, on the main queue.
    func start(interval: TimeInterval = 15) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
    }

    private var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    func refresh() {
        let shared = ricohQueues().filter(\.shared)
        for (name, entry) in announced where !shared.contains(where: { $0 == entry.queue }) {
            DNSServiceRefDeallocate(entry.ref)
            announced[name] = nil
            log("AirPrint: stopped announcing \(name)")
        }
        for queue in shared where announced[queue.name] == nil {
            if let ref = register(queue) {
                announced[queue.name] = (queue, ref)
                log("AirPrint: announcing \(queue.name) to iPhones and iPads on the network")
            }
        }
        for queue in shared where queue.onlySomeUsers && !warned.contains(queue.name) {
            warned.insert(queue.name)
            log("AirPrint: \(queue.name) only accepts some user names, so iPhones may be refused; " +
                "to let anyone on the network print to it: lpadmin -p \(queue.name) -u allow:all")
        }
        warned = warned.filter { name in shared.contains { $0.name == name && $0.onlySomeUsers } }
    }

    private func register(_ queue: PrintQueue) -> DNSServiceRef? {
        // macOS announces the shared queue itself as "<description> @ <computer>"; this name must
        // differ from that, or the second announcement is silently dropped.
        var label = queue.info.replacingOccurrences(of: " (macOS driver)", with: "")
        if label == queue.info { label += " AirPrint" }
        let name = String("\(label) @ \(computerName)".prefix(63))
        var pairs = ["txtvers=1", "qtotal=1", "rp=printers/\(queue.name)", "ty=Ricoh SP 210 series",
                     "product=(Ricoh SP 210 series)", "note=\(computerName)",
                     "pdl=application/pdf,image/urf,image/jpeg,image/png",
                     "URF=W8,RS600,CP1,IS1,MT1,PQ4", "Color=F", "Duplex=F", "Copies=T", "Transparent=T",
                     "Binary=T", "kind=document", "printer-state=3", "air=none"]
        if !queue.uuid.isEmpty { pairs.append("UUID=\(queue.uuid)") }
        let txt = txtRecord(pairs)
        var ref: DNSServiceRef?
        let err = txt.withUnsafeBytes { t in
            DNSServiceRegister(&ref, 0, 0, name, "_ipp._tcp,_universal", nil, nil, UInt16(631).bigEndian,
                               UInt16(t.count), t.baseAddress, { _, _, err, _, _, _, _ in
                if err != kDNSServiceErr_NoError { log("AirPrint: announcement failed (\(err))") }
            }, nil)
        }
        guard err == kDNSServiceErr_NoError, let ref else {
            log("AirPrint: cannot announce \(queue.name) (\(err))")
            return nil
        }
        DNSServiceSetDispatchQueue(ref, .main)
        return ref
    }
}
