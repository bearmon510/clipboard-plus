import Foundation
import XCTest
@testable import ClipboardPlus

final class WifiProbeTests: XCTestCase {
    func testQRPayloadRoundTripsAndDistinguishesPrefix() throws {
        let original = try WifiProbeQR(
            ssid: "DIRECT-cp-ABCD1234",
            passphrase: "TestPassword1234",
            ip: "192.168.137.1",
            port: 54321,
            token: "token_value_1234567890"
        )
        let qrText = try original.qrString()
        XCTAssertTrue(qrText.hasPrefix(WifiProbeQR.prefix))

        let parsed = try WifiProbeQR.parse(qrText)
        XCTAssertEqual(parsed, original)
    }

    func testQRParserRejectsPairingQRAndInvalidPayloads() {
        XCTAssertThrowsError(try WifiProbeQR.parse("clipboardplus-pair:1:abc:def:PC")) { error in
            XCTAssertEqual(error as? WifiProbeQRError, .pairingQR)
        }
        XCTAssertThrowsError(try WifiProbeQR.parse("https://example.com")) { error in
            XCTAssertEqual(error as? WifiProbeQRError, .wrongFormat)
        }
        XCTAssertThrowsError(try WifiProbeQR.parse(WifiProbeQR.prefix + "{invalid")) { error in
            XCTAssertEqual(error as? WifiProbeQRError, .invalidPayload)
        }

        // Loopback, zero, and leading-zero IPv4 should be rejected
        XCTAssertThrowsError(try WifiProbeQR.parse(
            WifiProbeQR.prefix + #"{"ssid":"DIRECT-cp-1","passphrase":"TestPassword1234","ip":"127.0.0.1","port":5000,"token":"token_value_12345678"}"#
        )) { error in
            XCTAssertEqual(error as? WifiProbeQRError, .invalidPayload)
        }
        XCTAssertThrowsError(try WifiProbeQR.parse(
            WifiProbeQR.prefix + #"{"ssid":"DIRECT-cp-1","passphrase":"TestPassword1234","ip":"0.0.0.0","port":5000,"token":"token_value_12345678"}"#
        )) { error in
            XCTAssertEqual(error as? WifiProbeQRError, .invalidPayload)
        }
        XCTAssertThrowsError(try WifiProbeQR.parse(
            WifiProbeQR.prefix + #"{"ssid":"DIRECT-cp-1","passphrase":"TestPassword1234","ip":"192.168.01.1","port":5000,"token":"token_value_12345678"}"#
        )) { error in
            XCTAssertEqual(error as? WifiProbeQRError, .invalidPayload)
        }

        // Port out of range and short passphrase rejected
        XCTAssertThrowsError(try WifiProbeQR.parse(
            WifiProbeQR.prefix + #"{"ssid":"DIRECT-cp-1","passphrase":"TestPassword1234","ip":"192.168.137.1","port":70000,"token":"token_value_12345678"}"#
        )) { error in
            XCTAssertEqual(error as? WifiProbeQRError, .invalidPayload)
        }
        XCTAssertThrowsError(try WifiProbeQR.parse(
            WifiProbeQR.prefix + #"{"ssid":"DIRECT-cp-1","passphrase":"short","ip":"192.168.137.1","port":5000,"token":"token_value_12345678"}"#
        )) { error in
            XCTAssertEqual(error as? WifiProbeQRError, .invalidPayload)
        }
    }

    func testWireHeaderEncodesAndDecodesAndValidatesSize() throws {
        let token = "token_value_1234567890"
        let bytes = WifiProbeSize.mb10.byteCount
        XCTAssertEqual(bytes, 10_485_760)
        XCTAssertEqual(WifiProbeSize.mb2.byteCount, 2_097_152)
        XCTAssertEqual(WifiProbeSize.mb50.byteCount, 52_428_800)

        let encoded = try WifiProbeWire.encodeHeader(token: token, payloadBytes: bytes)
        XCTAssertEqual(encoded.prefix(4), WifiProbeWire.magic)

        let decoded = try WifiProbeWire.decodeHeader(encoded)
        XCTAssertEqual(decoded.token, token)
        XCTAssertEqual(decoded.payloadBytes, bytes)

        XCTAssertThrowsError(try WifiProbeWire.encodeHeader(token: token, payloadBytes: 0)) { error in
            XCTAssertEqual(error as? WifiProbeWireError, .invalidSize)
        }
        XCTAssertThrowsError(try WifiProbeWire.encodeHeader(token: token, payloadBytes: WifiProbeWire.maxPayloadBytes + 1)) { error in
            XCTAssertEqual(error as? WifiProbeWireError, .invalidSize)
        }
    }

    func testSpeedMetricsAndTimelineRowsFormatExpectedStages() {
        let speed = WifiProbeMetrics.speedMBPerSecond(bytes: WifiProbeSize.mb10.byteCount, duration: 2.0)
        XCTAssertEqual(speed, 5.0)
        XCTAssertEqual(WifiProbeMetrics.formatSpeed(speed), "5.00 MB/秒")
        XCTAssertNil(WifiProbeMetrics.speedMBPerSecond(bytes: 0, duration: 1.0))
        XCTAssertNil(WifiProbeMetrics.speedMBPerSecond(bytes: 1024, duration: 0))
        XCTAssertEqual(WifiProbeMetrics.formatSpeed(nil), "-")
        XCTAssertEqual(WifiProbeMetrics.formatBytes(WifiProbeSize.mb50.byteCount), "50 MB")

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let timeline = WifiProbeTimeline(
            payloadBytes: WifiProbeSize.mb10.byteCount,
            joinPromptedAt: base,
            joinedAt: base.addingTimeInterval(2.5),
            connectedAt: base.addingTimeInterval(3.5),
            uploadStartedAt: base.addingTimeInterval(3.6),
            sentAt: base.addingTimeInterval(4.6),
            receivedAt: base.addingTimeInterval(5.1),
            restoreStartedAt: base.addingTimeInterval(5.1),
            restoredAt: base.addingTimeInterval(7.1)
        )

        let rows = timeline.rows(timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(rows.map(\.label), [
            "参加の確認を出した",
            "参加できた",
            "つながった",
            "送り終えた",
            "受け取り終えた",
            "元の Wi-Fi に戻った",
        ])
        XCTAssertEqual(rows[1].detailText, "所要 2.50 秒")
        XCTAssertEqual(rows[2].detailText, "参加後 1.00 秒")
        XCTAssertEqual(rows[3].detailText, "1.00 秒 · 10.00 MB/秒")
        XCTAssertEqual(rows[4].detailText, "0.50 秒 · 20.00 MB/秒")
        XCTAssertEqual(rows[5].detailText, "復帰 2.00 秒 · 合計 7.10 秒")
    }
}
