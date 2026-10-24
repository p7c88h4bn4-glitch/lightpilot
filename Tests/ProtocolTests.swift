import XCTest
@testable import LightPilot

final class ProtocolTests: XCTestCase {

    func testAllCapturedFixturesRoundTrip() {
        let results = ProtocolSelfTest.run()
        XCTAssertEqual(results.count, 2 + 25 + 2)
        for r in results {
            XCTAssertTrue(r.passed, "\(r.name): \(r.detail)")
        }
    }

    func testKnownDecryptedOffAndOn() throws {
        let off = try XCTUnwrap(IStrip.decrypt(try XCTUnwrap([UInt8](hex: IStrip.fixtureOff))))
        XCTAssertEqual(Array(off.prefix(6)), [0x05, 0x54, 0x55, 0x52, 0x4E, 0x00])
        let on = try XCTUnwrap(IStrip.decrypt(try XCTUnwrap([UInt8](hex: IStrip.fixtureOn))))
        XCTAssertEqual(Array(on.prefix(6)), [0x05, 0x54, 0x55, 0x52, 0x4E, 0x01])
    }

    func testDecryptedSGLSMode1MatchesHandoff() throws {
        // Browse #1 = SGLS mode 1: 0E 'SGLS' 01 00 64 22 F6F6F6 0000FF 46
        let mode = IStrip.modes[0]
        let p = try XCTUnwrap(IStrip.decrypt(try XCTUnwrap([UInt8](hex: mode.fixture))))
        XCTAssertEqual(p, [0x0E, 0x53, 0x47, 0x4C, 0x53, 0x01, 0x00, 0x64, 0x22,
                           0xF6, 0xF6, 0xF6, 0x00, 0x00, 0xFF, 0x46])
    }

    func testCatalogHasOnlyObservedIDs() {
        XCTAssertEqual(IStrip.modes.count, 25)
        let sgls = IStrip.modes.filter { $0.bank == .sgls }.map { Int($0.id) }.sorted()
        let mult = IStrip.modes.filter { $0.bank == .mult }.map { Int($0.id) }.sorted()
        XCTAssertEqual(sgls, Array(0...9))
        XCTAssertEqual(mult, Array(0...14))
        XCTAssertEqual(IStrip.modes.map { $0.browse }, Array(0..<25))
    }

    func testPacketsAreExactlyOneBlock() {
        XCTAssertEqual(IStrip.turn(true, filler: .random).count, 16)
        XCTAssertEqual(IStrip.sgls(mode: 9, speed: 100, a: .black, b: .black, filler: .random).count, 16)
        XCTAssertEqual(IStrip.mult(mode: 14, speed: 0, filler: .zero).count, 16)
        XCTAssertEqual(IStrip.encrypt(IStrip.turn(true, filler: .zero))?.count, 16)   // no PKCS#7 block
        XCTAssertNil(IStrip.encrypt([UInt8](repeating: 0, count: 15)))
        XCTAssertNil(IStrip.encrypt([UInt8](repeating: 0, count: 17)))
    }

    func testFirstByteIsMeaningfulLength() {
        XCTAssertEqual(IStrip.turnMeaningful(true).count - 1, 0x05)
        XCTAssertEqual(IStrip.sglsMeaningful(mode: 0, speed: 0, a: .black, b: .black).count - 1, 0x0E)
        XCTAssertEqual(IStrip.multMeaningful(mode: 0, speed: 0).count - 1, 0x09)
        XCTAssertEqual(IStrip.paletteMeaningful(PaletteLibrary.captured).count - 1, 0x16)
    }

    func testZeroFillerAndBounds() {
        let p = IStrip.mult(mode: 3, speed: 250, filler: .zero)
        XCTAssertEqual(p[8], 100, "speed clamps to 100")
        XCTAssertEqual(Array(p[10...]), [UInt8](repeating: 0, count: 6))
    }

    func testPaletteSanitizedTail() {
        let d = IStrip.palette(PaletteLibrary.captured, length: 100)
        XCTAssertEqual(d.count, 100)
        XCTAssertEqual(Array(d.prefix(23)),
                       [UInt8](hex: "16 00 FF 00 00 FF A2 00 FF FF 00 00 FF 00 00 00 FF FF 00 FF FF FF FF"))
        XCTAssertTrue(d.dropFirst(23).allSatisfy { $0 == 0 })
        XCTAssertEqual(IStrip.palette(PaletteLibrary.captured, length: 23).count, 23)
    }

    func testBrightnessScalesPaletteAndSGLSColors() {
        var s = LightState()
        s.patternIndex = 10            // MULT 0
        s.brightness = 50
        let pal = try? XCTUnwrap(IStrip.paletteFor(s))
        XCTAssertEqual(pal?[2], 0x80)  // 255 * 50% rounded
        s.patternIndex = 1             // SGLS 0
        s.hueA = 0; s.saturation = 100
        let cmd = IStrip.patternMeaningful(s, invertSpeed: false)
        XCTAssertEqual(Array(cmd[9...11]), [0x80, 0x00, 0x00])
        XCTAssertNil(IStrip.paletteFor(s))
    }

    func testSpeedInvert() {
        XCTAssertEqual(IStrip.wireSpeed(30, invert: false), 30)
        XCTAssertEqual(IStrip.wireSpeed(30, invert: true), 70)
        XCTAssertEqual(IStrip.wireSpeed(-5, invert: false), 0)
    }
}

final class BrowsingTests: XCTestCase {

    func testHysteresisHoldsNearBoundary() {
        // Sitting on 3, nudging to 3.6 should not flip with 0.15 hysteresis…
        XCTAssertEqual(PatternBrowser.quantize(position: 3.6, current: 3, count: 25, hysteresis: 0.15), 3)
        // …but 3.7 should.
        XCTAssertEqual(PatternBrowser.quantize(position: 3.7, current: 3, count: 25, hysteresis: 0.15), 4)
        // Without hysteresis, plain rounding.
        XCTAssertEqual(PatternBrowser.quantize(position: 3.51, current: 3, count: 25, hysteresis: 0), 4)
    }

    func testEndpointsAlwaysSnap() {
        XCTAssertEqual(PatternBrowser.quantize(position: 0, current: 1, count: 25, hysteresis: 0.45), 0)
        XCTAssertEqual(PatternBrowser.quantize(position: 24, current: 23, count: 25, hysteresis: 0.45), 24)
        XCTAssertEqual(PatternBrowser.quantize(position: 99, current: 0, count: 25, hysteresis: 0.15), 24)
    }

    func testCCScaling() {
        XCTAssertEqual(ControlTarget.pattern.value(fromCC: 0), 0)
        XCTAssertEqual(ControlTarget.pattern.value(fromCC: 127), 24)
        XCTAssertEqual(ControlTarget.power.value(fromCC: 63), 0)
        XCTAssertEqual(ControlTarget.power.value(fromCC: 64), 1)
        XCTAssertEqual(ControlTarget.speed.value(fromCC: 127), 100)
    }

    func testLatestStateWinsInCore() {
        let core = PerformanceCore(rt: nil, isPlugin: false, initial: nil)
        let sink = RecordingSink()
        core.setSink(sink)
        for i in 0..<200 { core.set(.pattern, Double(i % 25)) }
        core.set(.speed, 42)
        let done = expectation(description: "drain")
        core.queue.async { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(sink.last?.speed, 42)
        XCTAssertEqual(core.instanceState().state.speed, 42)
    }
}

private final class RecordingSink: LightSink {
    private let lock = NSLock()
    private var _last: LightState?
    var last: LightState? { lock.lock(); defer { lock.unlock() }; return _last }
    func submit(_ state: LightState) { lock.lock(); _last = state; lock.unlock() }
    func addStatusListener(_ listener: @escaping ([LightStatus]) -> Void) {}
    func reloadSettings() {}
    func start() {}
    func stop() {}
}
