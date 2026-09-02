// SPIKE-009 / SPIKE-004 observation recorder (throwaway).
// Usage: ble-observe <seconds> > out.jsonl
// Emits one JSON object per line: state changes, discoveries (all peripherals), and periodic summaries.
import Foundation
import CoreBluetooth

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "60") ?? 60
let t0 = ContinuousClock.now
func ms() -> Int64 { let d = ContinuousClock.now - t0; let (s, a) = d.components; return s * 1000 + a / 1_000_000_000_000_000 }
func emit(_ o: [String: Any]) {
    var o = o; o["t"] = ms()
    if let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8) { print(s); fflush(stdout) }
}

final class D: NSObject, CBCentralManagerDelegate {
    var counts: [UUID: Int] = [:]
    var names: [UUID: String] = [:]
    var apple: Set<UUID> = []
    var lastSeen: [UUID: Int64] = [:]
    var rssis: [UUID: [Int]] = [:]
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        emit(["kind": "state", "state": c.state.rawValue, "desc": "\(c.state)"])
        if c.state == .poweredOn {
            c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            emit(["kind": "scan", "action": "start", "isScanning": c.isScanning])
        }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData a: [String: Any], rssi: NSNumber) {
        let id = p.identifier
        counts[id, default: 0] += 1
        lastSeen[id] = ms()
        rssis[id, default: []].append(rssi.intValue)
        if let n = a[CBAdvertisementDataLocalNameKey] as? String ?? p.name { names[id] = n }
        var isApple = false
        if let m = a[CBAdvertisementDataManufacturerDataKey] as? Data, m.count >= 2, m[0] == 0x4C, m[1] == 0x00 { isApple = true; apple.insert(id) }
        // Only first 3 sightings per device are logged verbosely to keep output small; the rest go to summaries.
        if counts[id]! <= 3 {
            emit(["kind": "discover", "id": id.uuidString, "rssi": rssi.intValue, "name": names[id] ?? "", "apple": isApple,
                  "connectable": (a[CBAdvertisementDataIsConnectable] as? Bool) ?? false,
                  "services": ((a[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []).map { $0.uuidString },
                  "mfgLen": (a[CBAdvertisementDataManufacturerDataKey] as? Data)?.count ?? 0])
        }
    }
    func summary() {
        for (id, n) in counts.sorted(by: { $0.value > $1.value }) {
            let r = rssis[id] ?? []
            let sorted = r.sorted(); let med = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            emit(["kind": "summary", "id": id.uuidString, "name": names[id] ?? "", "apple": apple.contains(id), "count": n,
                  "medianRSSI": med, "minRSSI": sorted.first ?? 0, "maxRSSI": sorted.last ?? 0, "lastSeenMs": lastSeen[id] ?? -1])
        }
    }
}
let d = D()
let q = DispatchQueue(label: "spike.scan")
let central = CBCentralManager(delegate: d, queue: q)
emit(["kind": "start", "seconds": seconds, "initialState": central.state.rawValue])
var elapsed = 0.0
while elapsed < seconds {
    Thread.sleep(forTimeInterval: 10)
    elapsed += 10
    q.sync { emit(["kind": "tick", "elapsed": elapsed, "isScanning": central.isScanning, "state": central.state.rawValue]); d.summary() }
}
q.sync { central.stopScan(); d.summary() }
emit(["kind": "end"])
