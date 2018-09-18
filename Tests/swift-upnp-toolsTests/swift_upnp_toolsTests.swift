import XCTest
@testable import swift_upnp_tools

final class swift_upnp_toolsTests: XCTestCase {
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        XCTAssertEqual(swift_upnp_tools().text, "Hello, World!")
    }

    func testSsdp() {
        XCTAssertEqual(SSDP.MCAST_HOST, "239.255.255.250")
        XCTAssertEqual(SSDP.MCAST_PORT, 1900)
    }

    func testSsdpHeader() {
        let header = SSDPHeader()
        let location = "http://example.com"
        header["Location"] = location
        XCTAssertEqual(header["Location"], location)
        XCTAssertEqual(header["LOCATION"], location)
        XCTAssertEqual(header["location"], location)
    }

    func testSsdpHeaderToString() {
        let header = SSDPHeader()
        let location = "http://example.com"
        header["Location"] = location
        XCTAssertEqual(header.description, "\r\nLocation: http://example.com\r\n\r\n")
    }

    func testSsdpHeaderFromString() {
        let text = "M-SEARCH * HTTP/1.1\r\n" +
          "HOST: \(SSDP.MCAST_HOST):\(SSDP.MCAST_PORT)\r\n" +
          "MAN: \"ssdp:discover\"\r\n" +
          "MX: 3\r\n" +
          "ST: ssdp:all\r\n" +
          "\r\n"
        let header = SSDPHeader.read(text: text)
        XCTAssertEqual(header.description, text)

        XCTAssertEqual(header.firstLineParts[0], "M-SEARCH")
        XCTAssertEqual(header.firstLineParts[1], "*")
        XCTAssertEqual(header.firstLineParts[2], "HTTP/1.1")

        XCTAssert(header.isMsearch)
    }

    func testUPnPModel() {
        let model = UPnPModel()
        let udn = NSUUID().uuidString.lowercased()
        model["UDN"] = udn
        XCTAssertEqual(model["UDN"], udn)
    }

    func testUsn() {
        var usn = UPnPUsn.read(text: "uuid:fake::urn:subtype")
        XCTAssertEqual(usn.uuid, "uuid:fake")
        XCTAssertEqual(usn.type, "urn:subtype")
        XCTAssertEqual(usn.description, "uuid:fake::urn:subtype")

        usn = UPnPUsn.read(text: "uuid:fake")
        XCTAssertEqual(usn.uuid, "uuid:fake")
        XCTAssertEqual(usn.type, nil)
        XCTAssertEqual(usn.description, "uuid:fake")
    }

    func testXml() {
        let tag = XmlTag()
        tag.name = "a"
        XCTAssertEqual(tag.description, "<a />")

        tag.namespace = "x"
        XCTAssertEqual(tag.description, "<x:a />")

        tag.content = "A"
        XCTAssertEqual(tag.description, "<x:a>A</x:a>")

        tag.content = XmlTag(name: "wow").description
        XCTAssertEqual(tag.description, "<x:a><wow /></x:a>")
    }

    static var allTests = [
      ("testExample", testExample),
      ("testSsdp", testSsdp),
      ("testSsdpHeader", testSsdpHeader),
      ("testSsdpHeaderToString", testSsdpHeaderToString),
      ("testSsdpHeaderFromString", testSsdpHeaderFromString),
      ("testUPnPModel", testUPnPModel),
      ("testUsn", testUsn),
      ("testXml", testXml),
    ]
}
