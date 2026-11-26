import XCTest
@testable import PufferParty

/// Expected values come from running the web client's own functions in Node.
final class CoreTests: XCTestCase {
    func testCategoryKeyMatchesWeb() {
        XCTAssertEqual(Party.categoryKey("Name a way to prepare eggs"), "14ukyu2")
        XCTAssertEqual(Party.categoryKey("  Name   something sprayed out of a can "), "6jfoxe")
        XCTAssertEqual(Party.categoryKey("Café ☕"), "bvwcsz")
    }

    func testPufferThresholdsMatchWeb() {
        let expected = [1.3751629470847546, 2.312829652731307, 3.7968543890165165, 5.284086113248486, 6.982810407411307]
        let actual = PufferLevel.thresholds(holderSince: 1_795_664_754_252)
        XCTAssertEqual(actual.count, expected.count)
        for (a, e) in zip(actual, expected) { XCTAssertEqual(a, e, accuracy: 1e-12) }
        XCTAssertEqual(PufferLevel.level(heldSeconds: 0, thresholds: actual), 0)
        XCTAssertEqual(PufferLevel.level(heldSeconds: 2.4, thresholds: actual), 2)
        XCTAssertEqual(PufferLevel.level(heldSeconds: 30, thresholds: actual), 5)
    }

    func testNormalizeName() {
        XCTAssertEqual(Party.normalizeName("  glub   tron "), "glub tron")
        XCTAssertNil(Party.normalizeName("a"))
        XCTAssertNil(Party.normalizeName("bad<name>"))
        XCTAssertEqual(Party.normalizeName("abcdefghijklmnopqrst"), "abcdefghijklmnop")
        XCTAssertEqual(Party.normalizeName("Zoë_O'Neil-2"), "Zoë_O'Neil-2")
    }

    func testNormalizeCode() {
        XCTAssertEqual(Party.normalizeCode(" krlp "), "KRLP")
        XCTAssertNil(Party.normalizeCode("KRL"))
        XCTAssertNil(Party.normalizeCode("KRLI"), "I and O are not in the room alphabet")
    }

    func testPatchMergesPlayersEventsAndChat() throws {
        let base = try XCTUnwrap(JSONValue.parse("""
        {"code":"KRLP","version":4,"phase":"round","holderId":"a","now":1,
         "players":[{"id":"a","seat":0,"lives":2},{"id":"b","seat":1,"lives":2}],
         "events":[{"seq":1,"kind":"start"}],"chat":[{"id":1,"playerId":null,"name":"","text":"hi"}]}
        """))
        let patch = try XCTUnwrap(JSONValue.parse("""
        {"base":4,"v":5,"now":2,"set":{"holderId":"b","holderSince":null},
         "players":[{"id":"c","seat":2,"lives":1},{"id":"a","seat":0,"lives":1}],"drop":["b"],
         "events":[{"seq":2,"kind":"pass","from":"a","to":"b","answer":"x","tier":"rare"}],"eventsLength":2,
         "chat":[{"id":2,"playerId":"a","name":"A","text":"yo"}],"chatLength":1}
        """))
        let merged = try XCTUnwrap(RoomPatch.apply(base, patch))
        let room = try XCTUnwrap(Room(json: merged))
        XCTAssertEqual(room.version, 5)
        XCTAssertEqual(room.holderId, "b")
        XCTAssertNil(room.holderSince)
        XCTAssertEqual(room.players.map(\.id), ["a", "c"])
        XCTAssertEqual(room.players.first?.lives, 1)
        XCTAssertEqual(room.events.map(\.seq), [1, 2])
        XCTAssertEqual(room.chat.map(\.id), [2])

        let stale = try XCTUnwrap(JSONValue.parse(#"{"base":3,"v":5,"now":2}"#))
        XCTAssertNil(RoomPatch.apply(base, stale))
    }

    func testHeartMeterReconcile() {
        let segs = [MeterSegment(tier: "rare", amount: 60), MeterSegment(tier: "plankton", amount: 10)]
        XCTAssertEqual(HeartMeter.reconcile(segs, meter: 70, target: 600), segs)
        XCTAssertEqual(HeartMeter.reconcile(segs, meter: 100, target: 600).first, MeterSegment(tier: nil, amount: 30))
        XCTAssertEqual(HeartMeter.reconcile(segs, meter: 20, target: 600),
                       [MeterSegment(tier: "rare", amount: 10), MeterSegment(tier: "plankton", amount: 10)])
        XCTAssertEqual(HeartMeter.reconcile(segs, meter: 0, target: 600), [])
    }

    func testBooleanParsingIsNotNumeric() throws {
        let json = try XCTUnwrap(JSONValue.parse(#"{"a":true,"b":1}"#))
        XCTAssertEqual(json["a"], .bool(true))
        XCTAssertEqual(json["b"], .number(1))
    }
}
