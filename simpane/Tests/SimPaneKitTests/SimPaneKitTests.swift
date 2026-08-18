//  Tests for the parts of SimPaneKit that need no simulator.
//
//  Anything that talks to a device belongs in the POC's diagnostics, which run
//  against real hardware state; these are the pure ones, so `swift test` stays
//  runnable on a machine with no Xcode at all.

import XCTest
@testable import SimPaneKit

final class SimDeviceInfoTests: XCTestCase {

    func testParsesSimctlStateNames() {
        XCTAssertEqual(SimDeviceInfo.State(simctlName: "Booted"), .booted)
        XCTAssertEqual(SimDeviceInfo.State(simctlName: "Shutdown"), .shutdown)
        XCTAssertEqual(SimDeviceInfo.State(simctlName: "Shutting Down"), .shuttingDown)
        XCTAssertEqual(SimDeviceInfo.State(simctlName: "Creating"), .creating)
        XCTAssertEqual(SimDeviceInfo.State(simctlName: "Booting"), .booting)
    }

    /// An unrecognised state must not be guessed at — a future simctl spelling
    /// should read as "unknown", never accidentally as "booted".
    func testUnknownSimctlStateIsUnknown() {
        XCTAssertEqual(SimDeviceInfo.State(simctlName: "Hibernating"), .unknown)
        XCTAssertEqual(SimDeviceInfo.State(simctlName: ""), .unknown)
    }

    func testParsesCoreSimulatorStateValues() {
        XCTAssertEqual(SimDeviceInfo.State(coreSimulatorValue: 0), .creating)
        XCTAssertEqual(SimDeviceInfo.State(coreSimulatorValue: 1), .shutdown)
        XCTAssertEqual(SimDeviceInfo.State(coreSimulatorValue: 2), .booting)
        XCTAssertEqual(SimDeviceInfo.State(coreSimulatorValue: 3), .booted)
        XCTAssertEqual(SimDeviceInfo.State(coreSimulatorValue: 4), .shuttingDown)
        XCTAssertEqual(SimDeviceInfo.State(coreSimulatorValue: -1), .unknown)
        XCTAssertEqual(SimDeviceInfo.State(coreSimulatorValue: 99), .unknown)
    }

    func testRuntimeIsHumanReadable() {
        let device = SimDeviceInfo(
            udid: "X", name: "iPhone 17 Pro",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-3", state: .booted)
        XCTAssertEqual(device.runtime, "iOS 26.3")
        XCTAssertTrue(device.isBooted)
    }

    func testRuntimeSurvivesAnUnexpectedIdentifier() {
        let device = SimDeviceInfo(
            udid: "X", name: "n", runtimeIdentifier: "something-else", state: .shutdown)
        XCTAssertEqual(device.runtime, "something else")
        XCTAssertFalse(device.isBooted)
    }
}

final class HardwareButtonTests: XCTestCase {

    /// The wire values are what the guest dispatches on; a wrong one is a button
    /// that does nothing or the wrong thing. Pinned against Indigo.h.
    func testWireValues() {
        XCTAssertEqual(HardwareButton.home.wire.rawValue, 0x0)
        XCTAssertEqual(HardwareButton.lock.wire.rawValue, 0x1)
        XCTAssertEqual(HardwareButton.applePay.wire.rawValue, 0x1f4)
        XCTAssertEqual(HardwareButton.side.wire.rawValue, 0xbb8)
        XCTAssertEqual(HardwareButton.siri.wire.rawValue, 0x0040_0002)
    }

    /// Every case must map to something; a new button added without a wire value
    /// should fail to compile, and this catches the case where it silently maps
    /// to a duplicate instead.
    func testEveryButtonHasADistinctWireValue() {
        let values = Set(HardwareButton.allCases.map { $0.wire.rawValue })
        XCTAssertEqual(values.count, HardwareButton.allCases.count)
    }
}

final class SupportTests: XCTestCase {

    func testUnsupportedCarriesItsReason() {
        let support = SimPaneSupport.unsupported(reason: "no Xcode")
        XCTAssertFalse(support.isSupported)
        XCTAssertEqual(support.reason, "no Xcode")

        XCTAssertTrue(SimPaneSupport.supported.isSupported)
        XCTAssertNil(SimPaneSupport.supported.reason)
    }

    /// The reason is shown to a user, so it has to survive the trip through
    /// Swift's Error bridging rather than becoming "operation could not be
    /// completed".
    func testErrorMessageSurvivesBridging() {
        let error: Error = SimPaneError("device is Shutdown; it must be booted to mirror")
        XCTAssertEqual(error.localizedDescription, "device is Shutdown; it must be booted to mirror")
    }
}

final class FrameDifferenceTests: XCTestCase {

    func testIdenticalFramesDifferNotAtAll() {
        let frame: [UInt8] = [1, 2, 3, 4, 5]
        XCTAssertEqual(SimulatorSession.frameDifference(frame, frame), 0)
    }

    func testDifferenceIsTheFractionOfChangedSamples() {
        XCTAssertEqual(SimulatorSession.frameDifference([1, 2, 3, 4], [1, 2, 9, 9]), 0.5)
    }

    /// Samples that cannot be compared must read as "no response". The opposite
    /// default would turn a failed capture into a passing test.
    func testIncomparableSamplesReadAsNoChange() {
        XCTAssertEqual(SimulatorSession.frameDifference([], []), 0)
        XCTAssertEqual(SimulatorSession.frameDifference([1, 2, 3], [1, 2]), 0)
    }
}
