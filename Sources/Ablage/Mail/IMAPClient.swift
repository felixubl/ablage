import Foundation
import Network

protocol IMAPTransport {
    func send(_ data: Data) throws
    func line() throws -> Data
    func bytes(_ count: Int) throws -> Data
    func close()
}

/// TLS is validated by Network.framework. All blocking work runs off the UI thread.
final class TLSMailTransport: IMAPTransport {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "at.fubl.ablage.imap.tls")
    private var buffer = Data()
    private var deadline = Date().addingTimeInterval(60)

    init(host: String, port: Int) throws {
        guard let port = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0), port.rawValue > 0 else { throw ConfigError(message: "Invalid IMAP port") }
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tls)
        let ready = DispatchSemaphore(value: 0)
        var failure: NWError?
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure = error; ready.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        guard ready.wait(timeout: .now() + 20) == .success else { connection.cancel(); throw ConfigError(message: "The IMAP connection timed out.") }
        if let failure { connection.cancel(); throw failure }
        connection.stateUpdateHandler = nil
    }
    deinit { close() }
    func close() { connection.cancel() }
    func send(_ data: Data) throws {
        deadline = Date().addingTimeInterval(60)
        let done = DispatchSemaphore(value: 0)
        var failure: NWError?
        connection.send(content: data, completion: .contentProcessed { error in failure = error; done.signal() })
        guard done.wait(timeout: .now() + 20) == .success else { throw ConfigError(message: "Sending the IMAP request timed out.") }
        if let failure { throw failure }
    }
    private func receive() throws {
        let done = DispatchSemaphore(value: 0)
        var chunk: Data?
        var failure: NWError?
        var ended = false
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            chunk = data; failure = error; ended = complete; done.signal()
        }
        guard done.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success else {
            close(); throw ConfigError(message: "Reading the IMAP response timed out.")
        }
        if let failure { throw failure }
        if let chunk, !chunk.isEmpty { buffer.append(chunk) }
        else if ended { throw ConfigError(message: "The mail server closed the connection.") }
    }
    func line() throws -> Data {
        let newline = Data([13, 10])
        while true {
            if let range = buffer.range(of: newline) {
                let value = Data(buffer[..<range.lowerBound]); buffer.removeSubrange(..<range.upperBound); return value
            }
            guard buffer.count < 1_048_576 else { throw ConfigError(message: "The mail server returned an oversized response line.") }
            try receive()
        }
    }
    func bytes(_ count: Int) throws -> Data {
        while buffer.count < count { try receive() }
        let value = Data(buffer.prefix(count)); buffer.removeFirst(count); return value
    }
}

struct IMAPResponse { var lines: [String] = []; var literals: [Data] = [] }
final class IMAPClient {
    private let transport: IMAPTransport
    private var sequence = 0
    private let byteLimit: Int
    init(transport: IMAPTransport, maxBytes: Int) throws {
        self.transport = transport; byteLimit = maxBytes
        let greeting = String(decoding: try transport.line(), as: UTF8.self)
        guard greeting.uppercased().hasPrefix("* OK") else { transport.close(); throw ConfigError(message: "The server did not offer an IMAP session.") }
    }
    deinit { transport.close() }
    static func quote(_ value: String) throws -> String {
        guard !value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }), value.utf8.count < 8192 else { throw ConfigError(message: "Invalid text in an IMAP field.") }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    func command(_ command: String) throws -> IMAPResponse {
        sequence += 1; let tag = "A\(sequence)"
        try transport.send(Data((tag + " " + command + "\r\n").utf8))
        var result = IMAPResponse(); var total = 0
        for _ in 0..<100000 {
            let raw = try transport.line(); total += raw.count
            guard total <= byteLimit else { throw ConfigError(message: "Message exceeds the configured size limit.") }
            let line = String(decoding: raw, as: UTF8.self)
            if line.hasPrefix(tag + " ") {
                guard line.uppercased().hasPrefix(tag + " OK") else { throw ConfigError(message: "The mail server declined the request. Check the account credentials, folder and app-password settings.") }
                return result
            }
            if line.uppercased().hasPrefix("* BYE") { throw ConfigError(message: "The mail server ended the session.") }
            result.lines.append(line)
            if let match = line.range(of: #"\{[0-9]+\+?\}$"#, options: .regularExpression) {
                let sizeText = line[match].filter(\.isNumber)
                guard let count = Int(sizeText), count <= byteLimit - total else { throw ConfigError(message: "Message exceeds the configured size limit.") }
                result.literals.append(try transport.bytes(count)); total += count
            }
        }
        throw ConfigError(message: "The mail server response did not finish.")
    }
    func login(username: String, password: String) throws { _ = try command("LOGIN \(Self.quote(username)) \(Self.quote(password))") }
    func examine(_ folder: String) throws -> UInt64 {
        let response = try command("EXAMINE " + Self.quote(Self.modifiedUTF7(folder)))
        for line in response.lines {
            guard let range = line.range(of: #"(?i)UIDVALIDITY\s+[0-9]+"#, options: .regularExpression), let value = UInt64(line[range].split(separator: " ").last ?? "") else { continue }
            return value
        }
        throw ConfigError(message: "The mail server did not provide a mailbox identity.")
    }
    func uids() throws -> [UInt64] {
        let response = try command("UID SEARCH ALL")
        return response.lines.filter { $0.uppercased().hasPrefix("* SEARCH") }.flatMap { $0.split(separator: " ").dropFirst(2).compactMap { UInt64($0) } }.sorted()
    }
    func message(_ uid: UInt64) throws -> Data {
        let response = try command("UID FETCH \(uid) (BODY.PEEK[])")
        guard response.literals.count == 1 else { throw ConfigError(message: "The message is no longer available or could not be read.") }
        return response.literals[0]
    }
    static func modifiedUTF7(_ text: String) -> String {
        var output = "", segment = ""
        func flush() {
            guard !segment.isEmpty else { return }
            let bytes = segment.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] }
            output += "&" + Data(bytes).base64EncodedString().replacingOccurrences(of: "/", with: ",").replacingOccurrences(of: "=", with: "") + "-"
            segment = ""
        }
        for scalar in text.unicodeScalars {
            if (0x20...0x7e).contains(scalar.value) { flush(); output += scalar == "&" ? "&-" : String(scalar) }
            else { segment.unicodeScalars.append(scalar) }
        }
        flush(); return output
    }
}
