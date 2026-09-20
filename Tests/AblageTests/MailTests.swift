import XCTest
@testable import Ablage

final class MailTests: XCTestCase {
    func testNestedMIMEAndEncodedFilenamesPreserveAttachmentBytes() throws {
        let bytes = Data([0, 1, 2, 13, 10, 255, 127])
        let message = """
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="outer"

        --outer
        Content-Type: multipart/alternative; boundary=inner

        --inner
        Content-Type: text/plain

        Hello.
        --inner--
        --outer
        Content-Type: application/pdf
        Content-Disposition: attachment;
         filename*=UTF-8''Rechnung%20f%C3%BCr%20Wien.pdf
        Content-Transfer-Encoding: base64

        \(bytes.base64EncodedString())
        --outer--

        """
        let result = try MIME.attachments(Data(message.replacingOccurrences(of: "\n", with: "\r\n").utf8), extensions: ["pdf"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "Rechnung für Wien.pdf")
        XCTAssertEqual(result.first?.data, bytes)
    }
    func testAttachmentNamesCannotEscapeInboxAndQuotedPrintableWorks() throws {
        let message = "Content-Type: application/pdf\nContent-Disposition: attachment; filename=\"../../bill.pdf\"\nContent-Transfer-Encoding: quoted-printable\n\nABC=00=FF=\n123"
        let result = try MIME.attachments(Data(message.utf8), extensions: ["pdf"])
        XCTAssertEqual(result.first?.name, "bill.pdf")
        XCTAssertEqual(result.first?.data, Data([65,66,67,0,255,49,50,51]))
        XCTAssertEqual(MIME.safeName(#"C:\Downloads\report.pdf"#), "report.pdf")
        XCTAssertEqual(MIME.decodeWords("=?UTF-8?B?UsOpw6d1LnBkZg==?="), "Réçu.pdf")
        XCTAssertThrowsError(try MIME.quotedPrintable("=XY"))
    }
    func testMalformedMultipartIsRetriedInsteadOfSilentlyDroppingAttachments() throws {
        let message = "Content-Type: multipart/mixed; boundary=part\n\n--part\nContent-Type: application/pdf\n\nunfinished"
        XCTAssertThrowsError(try MIME.attachments(Data(message.utf8), extensions: ["pdf"]))
    }
    func testInternationalAndLongAttachmentNamesKeepTheirExtensions() throws {
        let email = "Content-Type: application/pdf\r\nContent-Disposition: attachment; filename*=iso-8859-1''R%E9sum%E9.pdf\r\nContent-Transfer-Encoding: base64\r\n\r\nZG9jdW1lbnQ="
        XCTAssertEqual(try MIME.attachments(Data(email.utf8), extensions: ["pdf"]).first?.name, "Résumé.pdf")
        let long = MIME.safeName(String(repeating: "收据", count: 100) + ".pdf")
        XCTAssertTrue(long.hasSuffix(".pdf"))
        XCTAssertLessThan(long.utf8.count, 255)
    }
    func testIMAPUsesUIDsReadOnlyFolderAndPeekLiterals() throws {
        let payload = Data("Subject: Trap\r\n\r\nA4 OK not a protocol response\r\n".utf8)
        let transport = ScriptedIMAP(lines: [
            "* OK ready", "A1 OK logged in", "* OK [UIDVALIDITY 42] stable", "A2 OK read only",
            "* SEARCH 7 19", "A3 OK searched", "* 2 FETCH (UID 19 BODY[] {\(payload.count)}", ")", "A4 OK done"
        ], literals: [payload])
        let client = try IMAPClient(transport: transport, maxBytes: 10000)
        try client.login(username: "test", password: #"p"ass\word"#)
        XCTAssertEqual(try client.examine("Receipts"), 42)
        XCTAssertEqual(try client.uids(), [7,19])
        XCTAssertEqual(try client.message(19), payload)
        XCTAssertTrue(transport.sent.contains { $0.contains("EXAMINE \"Receipts\"") })
        XCTAssertTrue(transport.sent.contains { $0.contains("UID FETCH 19 (BODY.PEEK[])") })
        XCTAssertFalse(transport.sent.contains { $0.contains("SELECT ") || $0.contains("STORE ") || $0.contains("EXPUNGE") })
        XCTAssertThrowsError(try IMAPClient.quote("bad\r\nSTORE 1 +FLAGS (\\Deleted)"))
        XCTAssertEqual(IMAPClient.modifiedUTF7("A&B"), "A&-B")
        XCTAssertEqual(IMAPClient.modifiedUTF7("台北"), "&U,BTFw-")
    }
    func testOversizedLiteralsAreRejectedBeforeReadingThem() throws {
        let transport = ScriptedIMAP(lines: ["* OK ready", "* 1 FETCH (BODY[] {1000000}"], literals: [])
        let client = try IMAPClient(transport: transport, maxBytes: 1000)
        XCTAssertThrowsError(try client.message(1))
        XCTAssertEqual(transport.byteReads, 0)
    }
    func testDeliveryRecoveryDoesNotRepeatAnAlreadyMovedAttachment() throws {
        let root = URL(fileURLWithPath: "/private/tmp/ablage-mail-" + UUID().uuidString)
        let inbox = root.appendingPathComponent("inbox"), staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = MailAttachment(name: "bill.pdf", data: Data("document".utf8))
        var state = MailCheckpoint(), durable = MailCheckpoint()
        var saves = 0
        XCTAssertThrowsError(try MailDeliveryStore.deliver("receipt", attachment: attachment, into: inbox, directory: staging, state: &state) { value in
            saves += 1
            if saves == 2 { throw ConfigError(message: "simulated power loss after delivery") }
            durable = value
        })
        let delivered = inbox.appendingPathComponent("bill.pdf"), filed = root.appendingPathComponent("filed.pdf")
        try FileManager.default.moveItem(at: delivered, to: filed)
        state = durable
        _ = try MailDeliveryStore.deliver("receipt", attachment: attachment, into: inbox, directory: staging, state: &state) { durable = $0 }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: inbox.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: filed), attachment.data)
        XCTAssertEqual(durable.deliveries["receipt"]?.delivered, true)
    }
}

private final class ScriptedIMAP: IMAPTransport {
    var lines: [String]
    var literals: [Data]
    var sent: [String] = []
    var byteReads = 0
    init(lines: [String], literals: [Data]) { self.lines = lines; self.literals = literals }
    func send(_ data: Data) throws { sent.append(String(decoding: data, as: UTF8.self)) }
    func line() throws -> Data {
        guard !lines.isEmpty else { throw ConfigError(message: "Unexpected read") }
        return Data(lines.removeFirst().utf8)
    }
    func bytes(_ count: Int) throws -> Data {
        byteReads += 1
        guard !literals.isEmpty, literals[0].count == count else { throw ConfigError(message: "Unexpected literal") }
        return literals.removeFirst()
    }
    func close() {}
}
