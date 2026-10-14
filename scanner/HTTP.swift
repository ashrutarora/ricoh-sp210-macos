// A small HTTP/1.1 server on 127.0.0.1, one thread per connection. Strict on purpose: a request
// it does not like gets a 4xx reply and the connection is closed, so nothing it did not read can
// be taken as a further request on the same connection (request smuggling).
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

struct Request {
    let method: String
    let path: String
    let headers: [(String, String)]    // names in lower case
    let body: Data

    /// The first header with this (lower-case) name.
    func header(_ name: String) -> String? { headers.first { $0.0 == name }?.1 }
}

struct Response {
    let code: Int
    let body: Data
    let type: String
    let headers: [(String, String)]
    let quiet: Bool                    // not logged (status polls every few seconds)

    init(_ code: Int, _ body: String = "", headers: [(String, String)] = [], quiet: Bool = false) {
        self.init(code, Data(body.utf8), type: "text/xml", headers: headers, quiet: quiet)
    }

    init(_ code: Int, _ body: Data, type: String, headers: [(String, String)] = [], quiet: Bool = false) {
        self.code = code
        self.body = body
        self.type = type
        self.headers = headers
        self.quiet = quiet
    }
}

private let reasons = [200: "OK", 201: "Created", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                       408: "Request Timeout", 411: "Length Required", 413: "Content Too Large",
                       431: "Request Header Fields Too Large", 500: "Internal Server Error",
                       501: "Not Implemented", 503: "Service Unavailable"]

let maxHeaderBytes = 16 * 1024
let maxBodyBytes = 1 << 20
let maxConnections = 32
let idleTimeout = 60                   // seconds without a byte from the client

final class HTTPServer {
    private let listener: Int32
    private let handler: (Request) -> Response
    private let lock = NSLock()
    private var open = 0

    init(port: UInt16, handler: @escaping (Request) -> Response) throws {
        signal(SIGPIPE, SIG_IGN)
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw ScannerError("socket: \(String(cString: strerror(errno)))") }
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listener, 16) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(listener)
            throw ScannerError("cannot listen on 127.0.0.1:\(port): \(reason)")
        }
        self.listener = listener
        self.handler = handler
    }

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { continue }
                let admitted = lock.withLock { () -> Bool in
                    if open >= maxConnections { return false }
                    open += 1
                    return true
                }
                guard admitted else { Darwin.close(client); continue }
                Thread.detachNewThread { [self] in
                    serve(client)
                    lock.withLock { open -= 1 }
                }
            }
        }
    }

    private func serve(_ fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: idleTimeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = Data()
        defer {
            shutdown(fd, SHUT_WR)
            Darwin.close(fd)
        }
        while true {
            switch readRequest(fd, &buffer) {
            case .closed:
                return
            case .refused(let code, let why):
                log("refused request: \(why)")
                send(fd, Response(code), keepAlive: false)
                return
            case .request(let request, let keepAlive):
                let response = handler(request)
                if !response.quiet { log("\(request.method) \(request.path) \(response.code)") }
                // After a refusal or error, stop: never read on into a request body we did not want.
                let again = keepAlive && response.code < 400
                guard send(fd, response, keepAlive: again), again else { return }
            }
        }
    }

    private enum Read {
        case request(Request, keepAlive: Bool)
        case refused(Int, String)
        case closed
    }

    private func fill(_ fd: Int32, _ buffer: inout Data) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let n = recv(fd, &chunk, chunk.count, 0)
        guard n > 0 else { return false }
        buffer.append(contentsOf: chunk[0..<n])
        return true
    }

    private func readRequest(_ fd: Int32, _ buffer: inout Data) -> Read {
        let end = Data("\r\n\r\n".utf8)
        var headEnd: Range<Data.Index>?
        while true {
            headEnd = buffer.range(of: end)
            if headEnd != nil { break }
            if buffer.count > maxHeaderBytes { return .refused(431, "headers too long") }
            guard fill(fd, &buffer) else { return .closed }
        }
        let head = buffer[buffer.startIndex..<headEnd!.lowerBound]
        buffer = Data(buffer[headEnd!.upperBound...])
        guard head.count <= maxHeaderBytes, let text = String(data: head, encoding: .isoLatin1) else {
            return .refused(431, "headers too long")
        }
        var lines = text.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3, start[2] == "HTTP/1.1" || start[2] == "HTTP/1.0",
              !start[0].isEmpty, start[1].hasPrefix("/") else {
            return .refused(400, "bad request line")
        }
        var headers: [(String, String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                return .refused(400, "bad header line")
            }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, !name.contains(" ") else { return .refused(400, "bad header name") }
            headers.append((name, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        func all(_ name: String) -> [String] { headers.filter { $0.0 == name }.map(\.1) }

        // Bodies only with a single, plain Content-Length: no chunked encoding, nothing ambiguous.
        if !all("transfer-encoding").isEmpty { return .refused(411, "Transfer-Encoding") }
        let lengths = all("content-length")
        var length = 0
        if !lengths.isEmpty {
            guard lengths.count == 1, let n = Int(lengths[0]), n >= 0 else {
                return .refused(400, "bad Content-Length")
            }
            length = n
        }
        if length > maxBodyBytes { return .refused(413, "body too big") }
        while buffer.count < length {
            guard fill(fd, &buffer) else { return .closed }
        }
        let body = Data(buffer.prefix(length))
        buffer = Data(buffer.dropFirst(length))

        let connection = all("connection").joined(separator: ",").lowercased()
        let keepAlive = start[2] == "HTTP/1.1" && !connection.contains("close")
        return .request(Request(method: String(start[0]), path: String(start[1]), headers: headers, body: body),
                        keepAlive: keepAlive)
    }

    @discardableResult
    private func send(_ fd: Int32, _ response: Response, keepAlive: Bool) -> Bool {
        var head = "HTTP/1.1 \(response.code) \(reasons[response.code] ?? "Error")\r\n" +
                   "Content-Type: \(response.type)\r\nContent-Length: \(response.body.count)\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        if !keepAlive { head += "Connection: close\r\n" }
        head += "\r\n"
        return writeAll(fd, Data(head.utf8)) && writeAll(fd, response.body)
    }

    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { p in
            var offset = 0
            while offset < p.count {
                let n = Darwin.send(fd, p.baseAddress! + offset, p.count - offset, 0)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}
