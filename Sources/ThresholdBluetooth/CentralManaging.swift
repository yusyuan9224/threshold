import CoreBluetooth
import Dispatch
import Foundation

/// The minimum face of `CBCentralManager` the scanner actually uses.
///
/// It exists so `CoreBluetoothScanner` can be exercised without a radio: the whole
/// point of the seam is that scan lifecycle, state mapping and queue confinement are
/// testable, which they are not if the scanner news up a `CBCentralManager` itself.
///
/// Not `Sendable`: conforming objects are created on, and only ever touched from,
/// the scanner's serial `scanQueue`.
protocol CentralManaging: AnyObject {
    var state: CBManagerState { get }
    var isScanning: Bool { get }
    func scanForPeripherals(withServices services: [CBUUID]?, options: [String: Any]?)
    func stopScan()
}

/// Delegate callbacks, narrowed to the two events MVP 1 consumes.
///
/// MVP 1 is advertisement-only (bluetooth.md §4): no connect, no `readRSSI`. So there
/// is no `didConnect`/`didFailToConnect` here, and `CBPeripheral` never leaves the
/// adapter — only its identifier does.
///
/// Every call must arrive on the queue handed to the central.
protocol CentralEventSink: AnyObject {
    func didUpdateState(_ state: CBManagerState)
    func didDiscover(identifier: UUID, name: String?, rssi: Int)
}

/// Production `CentralManaging`: owns the real `CBCentralManager` and forwards its
/// delegate callbacks, which CoreBluetooth already delivers on the queue we hand it.
///
/// The sink is held weakly: the scanner owns this object, so a strong reference back
/// would be a cycle.
final class CoreBluetoothCentral: NSObject, CentralManaging, CBCentralManagerDelegate {
    private let manager: CBCentralManager
    private weak var sink: CentralEventSink?

    /// - Parameter queue: the scanner's serial `scanQueue`. Passing it here is what
    ///   makes delegate callbacks land on the queue that owns the scanner's state.
    init(queue: DispatchQueue, sink: CentralEventSink) {
        self.sink = sink
        // `delegate: nil` here, then assigned below: `self` is not available until
        // after `super.init()`.
        self.manager = CBCentralManager(delegate: nil, queue: queue)
        super.init()
        self.manager.delegate = self
    }

    var state: CBManagerState { manager.state }
    var isScanning: Bool { manager.isScanning }

    func scanForPeripherals(withServices services: [CBUUID]?, options: [String: Any]?) {
        manager.scanForPeripherals(withServices: services, options: options)
    }

    func stopScan() { manager.stopScan() }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        sink?.didUpdateState(central.state)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // The advertised local name is preferred over `peripheral.name`: the latter
        // can be a cached GATT name, and we only ever show this in the discovery UI.
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        sink?.didDiscover(
            identifier: peripheral.identifier,
            name: advertised ?? peripheral.name,
            rssi: RSSI.intValue
        )
    }
}
