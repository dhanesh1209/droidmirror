import XCTest
@testable import DroidMirrorCore

final class CoreTests: XCTestCase {
    func testParseDevices() {
        let out = """
        List of devices attached
        R5CT123ABC             device usb:1-1 product:b0s model:SM_S906B device:b0s transport_id:1
        192.168.1.20:5555      device product:husky model:Pixel_8_Pro device:husky transport_id:2
        ZZZ                    unauthorized usb:1-2 transport_id:3

        """
        let d = ADB.parseDevices(out)
        XCTAssertEqual(d.count, 3)
        XCTAssertEqual(d[0].model, "SM_S906B")
        XCTAssertFalse(d[0].isWireless)
        XCTAssertTrue(d[1].isWireless)
        XCTAssertFalse(d[2].isReady)
    }

    func testEmptyDevices() {
        XCTAssertTrue(ADB.parseDevices("List of devices attached\n\n").isEmpty)
    }

    func testScrcpyArguments() {
        var o = MirrorOptions(serial: "abc")
        o.audio = false
        o.maxSize = 1600
        XCTAssertEqual(o.arguments, ["--serial", "abc", "--turn-screen-off", "--stay-awake",
                                     "--no-audio", "--max-size", "1600", "--window-title", "DroidMirror"])
    }

    func testDeduperBaselineThenOnlyNew() {
        var d = NotificationDeduper()
        let a = PhoneNotification(key: "k1", package: "p", title: "A", text: "one")
        let b = PhoneNotification(key: "k2", package: "p", title: "B", text: "two")
        XCTAssertTrue(d.fresh([a]).isEmpty)                 // baseline: not replayed
        XCTAssertTrue(d.fresh([a]).isEmpty)                 // unchanged
        XCTAssertEqual(d.fresh([a, b]), [b])                // new one only
        let a2 = PhoneNotification(key: "k1", package: "p", title: "A", text: "updated")
        XCTAssertEqual(d.fresh([a2, b]), [a2])              // same key, new text
    }

    func testWiFiValidation() {
        XCTAssertTrue(WiFi.isValidEndpoint("192.168.1.20:39999"))
        XCTAssertTrue(WiFi.isValidEndpoint("pixel.local:5555"))
        XCTAssertFalse(WiFi.isValidEndpoint("-s:5555"))            // option-like
        XCTAssertFalse(WiFi.isValidEndpoint("192.168.1.20"))       // no port
        XCTAssertFalse(WiFi.isValidEndpoint("1.2.3.4:99999"))      // port out of range
        XCTAssertFalse(WiFi.isValidEndpoint("1.2.3.4:5555; ls"))
        XCTAssertTrue(WiFi.isValidPairingCode("123456"))
        XCTAssertFalse(WiFi.isValidPairingCode("12345"))
        XCTAssertFalse(WiFi.isValidPairingCode("12a456"))
    }

    func testWiFiOutputInterpretation() {
        XCTAssertTrue(WiFi.interpretPair("Successfully paired to 192.168.1.20:39999 [guid=adb-x]").success)
        XCTAssertFalse(WiFi.interpretPair("Failed: Wrong password or connection was dropped.").success)
        XCTAssertTrue(WiFi.interpretConnect("connected to 192.168.1.20:41234\n").success)
        XCTAssertTrue(WiFi.interpretConnect("already connected to 192.168.1.20:41234").success)
        XCTAssertFalse(WiFi.interpretConnect("failed to connect to '192.168.1.20:41234': Connection refused").success)
    }

    func testMdnsParsing() {
        // Synthetic sample of the documented `adb mdns services` shape; real output not yet captured.
        let out = """
        List of discovered mdns services
        adb-R5CT123-abc\t_adb-tls-connect._tcp.\t192.168.1.20:41234
        adb-R5CT123-abc\t_adb-tls-pairing._tcp.\t192.168.1.20:39999
        garbage line
        """
        let s = WiFi.parseMdnsServices(out)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].kind, .connect)
        XCTAssertEqual(s[1].endpoint, "192.168.1.20:39999")
    }

    func testParserMultilineBigTextAndFlags() {
        let dump = """
          NotificationRecord(0x1: pkg=com.example.mail user=UserHandle{0} id=1 tag=null importance=3 key=0|com.example.mail|1|null|10001 Notification(channel=m flags=GROUP_SUMMARY|ONGOING_EVENT color=0x0))
            extras={
              android.title=String (Subject line)
              android.text=String (short preview)
              android.bigText=SpannableString (line one
        line two
        line three)
              android.showWhen=Boolean (true)
            }
        """
        let n = NotificationParser.parse(dump)
        XCTAssertEqual(n.count, 1)
        XCTAssertEqual(n[0].title, "Subject line")
        XCTAssertEqual(n[0].text, "line one\nline two\nline three")   // bigText wins, multi-line kept
        XCTAssertTrue(n[0].isGroupSummary)
        XCTAssertTrue(n[0].isOngoing)
    }

    func testFilter() {
        let f = NotificationFilter()
        let normal = PhoneNotification(key: "k", package: "com.whatsapp", title: "A", text: "B")
        XCTAssertTrue(f.shouldForward(normal))
        XCTAssertFalse(f.shouldForward(PhoneNotification(key: "k", package: "android", title: "A", text: "B")))
        XCTAssertFalse(f.shouldForward(PhoneNotification(key: "k", package: "com.android.systemui", title: "A", text: "B")))
        XCTAssertFalse(f.shouldForward(PhoneNotification(key: "k", package: "com.x", title: "A", text: "B", flags: ["ONGOING_EVENT"])))
        XCTAssertFalse(f.shouldForward(PhoneNotification(key: "k", package: "com.x", title: "A", text: "B", flags: ["GROUP_SUMMARY"])))
    }

    func testAppNames() {
        XCTAssertEqual(AppNames.display(for: "com.whatsapp"), "WhatsApp")
        XCTAssertEqual(AppNames.display(for: "com.foo.bar.mail"), "Mail")
        XCTAssertEqual(AppNames.display(for: "com.acme.app"), "Acme")
        XCTAssertEqual(AppNames.display(for: "singleword"), "Singleword")
    }

    func testToolCheck() {
        XCTAssertTrue(ToolCheck.isAvailable("ls"))
        XCTAssertFalse(ToolCheck.isAvailable("definitely-not-a-real-tool-xyz"))
    }

    func testNotificationParser() {
        let dump = """
          NotificationRecord(0x1a2b: pkg=com.whatsapp user=UserHandle{0} id=1 tag=null importance=4 key=0|com.whatsapp|1|null|10123: Notification(channel=msg)
            extras={
              android.title=String (Alice)
              android.text=String (Dinner at 8?)
            }
          NotificationRecord(0x3c4d: pkg=android user=UserHandle{0} id=2 tag=null importance=1 key=0|android|2|null|1000: Notification(channel=x)
            extras={ }
        """
        let n = NotificationParser.parse(dump)
        XCTAssertEqual(n.count, 1)
        XCTAssertEqual(n[0].package, "com.whatsapp")
        XCTAssertEqual(n[0].title, "Alice")
        XCTAssertEqual(n[0].text, "Dinner at 8?")
    }
}
