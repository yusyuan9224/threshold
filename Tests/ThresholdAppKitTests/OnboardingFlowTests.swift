import Testing
import ThresholdBluetooth
import ThresholdDomain
import ThresholdSystem
@testable import ThresholdAppKit

@MainActor
@Suite struct OnboardingFlowTests {

    private func makeFlow() -> (OnboardingFlow, SpyOnboardingActions) {
        let actions = SpyOnboardingActions()
        return (OnboardingFlow(actions: actions), actions)
    }

    /// system-integration.md §6: Bluetooth is asked for first, and only after the explanation
    /// step. Nothing may create a `CBCentralManager` before the user presses the button.
    @Test func startsOnTheBluetoothExplanationWithoutScanning() {
        let (flow, actions) = makeFlow()
        #expect(flow.step == .bluetooth)
        #expect(flow.isScanning == false)
        #expect(actions.startDiscoveryCount == 0)
    }

    @Test func startScanningMovesToThePickerAndAsksForDiscovery() {
        let (flow, actions) = makeFlow()
        flow.startScanning()
        #expect(flow.step == .pickDevice)
        #expect(flow.isScanning)
        #expect(actions.startDiscoveryCount == 1)
    }

    @Test func discoveriesAreIgnoredBeforeScanningStarts() {
        let (flow, _) = makeFlow()
        flow.discovered(Fixtures.discovered(Fixtures.deviceA, name: "Phone", rssi: -50, atSecond: 0))
        #expect(flow.rows.isEmpty)
    }

    @Test func selectingARowPrefillsTheAdvertisedName() {
        let (flow, _) = makeFlow()
        flow.startScanning()
        flow.discovered(Fixtures.discovered(Fixtures.deviceA, name: "Phone", rssi: -50, atSecond: 0))
        flow.select(Fixtures.deviceA)
        #expect(flow.deviceName == "Phone")
        #expect(flow.canRegisterDevice)
    }

    /// The advertised name is a hint, not the stored value. A name the user is typing must
    /// survive them changing their mind about which row they meant.
    @Test func selectingAnotherRowDoesNotOverwriteATypedName() {
        let (flow, _) = makeFlow()
        flow.startScanning()
        flow.discovered(Fixtures.discovered(Fixtures.deviceA, name: "Phone", rssi: -50, atSecond: 0))
        flow.discovered(Fixtures.discovered(Fixtures.deviceB, name: "Watch", rssi: -60, atSecond: 0))
        flow.deviceName = "My phone"
        flow.select(Fixtures.deviceB)
        #expect(flow.deviceName == "My phone")
    }

    @Test func aBlankNameCannotRegisterADevice() {
        let (flow, actions) = makeFlow()
        flow.startScanning()
        flow.discovered(Fixtures.discovered(Fixtures.deviceA, name: nil, rssi: -50, atSecond: 0))
        flow.showEveryDevice = true
        flow.select(Fixtures.deviceA)
        flow.deviceName = "   "
        #expect(flow.canRegisterDevice == false)
        flow.registerSelectedDevice()
        #expect(actions.registered.isEmpty)
        #expect(flow.step == .pickDevice)
    }

    @Test func registeringADeviceStopsDiscoveryAndMovesToCalibration() {
        let (flow, actions) = makeFlow()
        flow.startScanning()
        flow.discovered(Fixtures.discovered(Fixtures.deviceA, name: "Phone", rssi: -50, atSecond: 0))
        flow.select(Fixtures.deviceA)
        flow.registerSelectedDevice()

        #expect(actions.registered == [RegisteredDevice(id: Fixtures.deviceA, name: "Phone")])
        #expect(actions.stopDiscoveryCount == 1)
        #expect(flow.isScanning == false)
        #expect(flow.step == .calibrate)
    }

    /// Advancing past a device that was never written would leave the user calibrating
    /// something the app will have forgotten by the next launch.
    @Test func aStoreFailureKeepsTheUserOnThePicker() {
        let (flow, actions) = makeFlow()
        actions.registerFailure = StoreError.writeFailed(file: "devices.json", message: "NSCocoaErrorDomain 513")
        flow.startScanning()
        flow.discovered(Fixtures.discovered(Fixtures.deviceA, name: "Phone", rssi: -50, atSecond: 0))
        flow.select(Fixtures.deviceA)
        flow.registerSelectedDevice()

        #expect(flow.step == .pickDevice)
        #expect(flow.errorMessage?.contains("devices.json") == true)
    }

    @Test func calibrationCanBeSkippedAndTheFlowRemembersThat() {
        let (flow, _) = makeFlow()
        flow.startScanning()
        flow.discovered(Fixtures.discovered(Fixtures.deviceA, name: "Phone", rssi: -50, atSecond: 0))
        flow.select(Fixtures.deviceA)
        flow.registerSelectedDevice()

        flow.skipCalibration()
        #expect(flow.step == .loginItem)
        #expect(flow.didCalibrate == false)
    }

    @Test func succeedingAtCalibrationAlsoReachesTheLoginItemStep() {
        let (flow, _) = makeFlow()
        flow.startScanning()
        flow.discovered(Fixtures.discovered(Fixtures.deviceA, name: "Phone", rssi: -50, atSecond: 0))
        flow.select(Fixtures.deviceA)
        flow.registerSelectedDevice()

        flow.calibrationSucceeded()
        #expect(flow.step == .loginItem)
        #expect(flow.didCalibrate)
    }

    /// The optional permission is last, and finishing is what tells the app onboarding is over.
    @Test func finishingCompletesOnboarding() {
        let (flow, actions) = makeFlow()
        flow.startScanning()
        flow.discovered(Fixtures.discovered(Fixtures.deviceA, name: "Phone", rssi: -50, atSecond: 0))
        flow.select(Fixtures.deviceA)
        flow.registerSelectedDevice()
        flow.skipCalibration()
        flow.finish()

        #expect(flow.step == .finished)
        #expect(actions.completeCount == 1)
    }

    @Test func cancellingFromTheFirstStepStopsWithoutRegisteringAnything() {
        let (flow, actions) = makeFlow()
        flow.cancel()
        #expect(flow.step == .finished)
        #expect(actions.registered.isEmpty)
        #expect(actions.completeCount == 1)
    }

    /// "Calibrate…" from the menu enters at step 3 and must not start a scan, because a user
    /// who already granted Bluetooth should not be re-prompted or made to pick a device again.
    @Test func jumpingToCalibrationSkipsDiscoveryEntirely() {
        let (flow, actions) = makeFlow()
        flow.jumpToCalibration()
        #expect(flow.step == .calibrate)
        #expect(actions.startDiscoveryCount == 0)
        #expect(flow.isScanning == false)
    }

    @Test func stepsAreOnlyEnteredFromTheirPredecessor() {
        let (flow, _) = makeFlow()
        // Calibration outcomes reported while still on step 1 must not skip the picker.
        flow.calibrationSucceeded()
        #expect(flow.step == .bluetooth)
        flow.skipCalibration()
        #expect(flow.step == .bluetooth)
    }
}

@MainActor
@Suite struct DiscoveryTableTests {

    @Test func countsSightingsAndKeepsTheLatestSignal() {
        var table = DiscoveryTable()
        table.ingest(Fixtures.discovered(Fixtures.deviceA, name: "Phone", rssi: -50, atSecond: 0))
        table.ingest(Fixtures.discovered(Fixtures.deviceA, name: "Phone", rssi: -62, atSecond: 3))

        let row = try? #require(table.rows().first)
        #expect(row?.sightings == 2)
        #expect(row?.rssi == -62)
        #expect(row?.firstSeen == Fixtures.instant(seconds: 0))
        #expect(row?.lastSeen == Fixtures.instant(seconds: 3))
    }

    /// Apple devices interleave named and unnamed advertisements; a row whose label flickers
    /// is worse than one that remembers.
    @Test func aNameOnceSeenIsNotLostToALaterUnnamedAdvertisement() {
        var table = DiscoveryTable()
        table.ingest(Fixtures.discovered(Fixtures.deviceA, name: "Phone", rssi: -50, atSecond: 0))
        table.ingest(Fixtures.discovered(Fixtures.deviceA, name: nil, rssi: -51, atSecond: 1))
        #expect(table.rows().first?.advertisedName == "Phone")
    }

    /// SPIKE-009 saw 56 identifiers in ten minutes of one ordinary room. The default filter is
    /// what keeps the picker usable.
    @Test func unnamedIdentifiersAreHiddenByDefaultAndCounted() {
        var table = DiscoveryTable()
        table.ingest(Fixtures.discovered(Fixtures.deviceA, name: "Phone", rssi: -70, atSecond: 0))
        for index in 0..<12 {
            table.ingest(Fixtures.discovered(DeviceID("noise-\(index)"), name: nil, rssi: -95, atSecond: 0))
        }
        #expect(table.rows().count == 1)
        #expect(table.rows(namedOnly: false).count == 13)
        #expect(table.totalSeen == 13)
    }

    @Test func namedDevicesSortAboveUnnamedOnesRegardlessOfSignal() {
        var table = DiscoveryTable()
        table.ingest(Fixtures.discovered(Fixtures.deviceA, name: nil, rssi: -30, atSecond: 0))
        table.ingest(Fixtures.discovered(Fixtures.deviceB, name: "Watch", rssi: -80, atSecond: 0))
        #expect(table.rows(namedOnly: false).map(\.id) == [Fixtures.deviceB, Fixtures.deviceA])
    }

    @Test func signalBarsCoverTheWholeRange() {
        func bars(_ rssi: Int) -> Int {
            DiscoveryRow(id: Fixtures.deviceA, advertisedName: nil, rssi: rssi, sightings: 1,
                         firstSeen: .zero, lastSeen: .zero).signalBars
        }
        #expect(bars(-95) == 0)
        #expect(bars(-85) == 1)
        #expect(bars(-75) == 2)
        #expect(bars(-65) == 3)
        #expect(bars(-40) == 4)
    }

    @Test func unnamedRowsRenderAsUnnamedDevice() {
        let row = DiscoveryRow(id: Fixtures.deviceA, advertisedName: nil, rssi: -70, sightings: 1,
                               firstSeen: .zero, lastSeen: .zero)
        #expect(row.displayName == "Unnamed device")
        #expect(row.hasName == false)
    }
}
