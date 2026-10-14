// Bonjour announcement of the AirScan service, so macOS apps list the scanner.
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import dnssd

private var connection: DNSServiceRef?
private var service: DNSServiceRef?
private var hostRecord: DNSRecordRef?

private func txtRecord(_ pairs: [String]) -> Data {
    var data = Data()
    for pair in pairs {
        let bytes = Array(pair.utf8.prefix(255))
        data.append(UInt8(bytes.count))
        data.append(contentsOf: bytes)
    }
    return data
}

/// Registers with macOS's own mDNSResponder: a host name pointing at 127.0.0.1 and the scan
/// service on it. Both are local only: announced on the network interfaces, a resolve can answer
/// on Wi-Fi, and macOS's AirScan helper then ties its connection to Wi-Fi, where 127.0.0.1 cannot
/// be reached (Image Capture shows -9921). The announcement goes away when the process exits.
func announce(name: String, port: UInt16) throws {
    let localOnly = UInt32.max              // kDNSServiceInterfaceIndexLocalOnly
    var err = DNSServiceCreateConnection(&connection)
    guard err == kDNSServiceErr_NoError else { throw ScannerError("Bonjour connection failed (\(err))") }

    var address: [UInt8] = [127, 0, 0, 1]
    err = DNSServiceRegisterRecord(connection, &hostRecord, DNSServiceFlags(kDNSServiceFlagsUnique), localOnly,
                                   bonjourHost + ".", UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                                   4, &address, 240, { _, _, _, err, _ in
        if err != kDNSServiceErr_NoError { log("Bonjour host record failed (\(err))") }
    }, nil)
    guard err == kDNSServiceErr_NoError else { throw ScannerError("Bonjour host record failed (\(err))") }

    let txt = txtRecord(["txtvers=1", "vers=2.0", "rs=eSCL", "ty=\(name)", "note=This Mac",
                         "uuid=\(scannerUUID)", "pdl=\(formats.joined(separator: ","))",
                         "cs=color,grayscale", "is=platen", "duplex=F"])
    service = connection
    err = txt.withUnsafeBytes { t in
        DNSServiceRegister(&service, DNSServiceFlags(kDNSServiceFlagsShareConnection), localOnly, name,
                           "_uscan._tcp", "local", bonjourHost + ".", port.bigEndian,
                           UInt16(t.count), t.baseAddress, { _, _, err, _, _, _, _ in
            if err != kDNSServiceErr_NoError { log("Bonjour registration failed (\(err))") }
        }, nil)
    }
    guard err == kDNSServiceErr_NoError else { throw ScannerError("Bonjour registration failed (\(err))") }
    DNSServiceSetDispatchQueue(connection, DispatchQueue.main)
}
