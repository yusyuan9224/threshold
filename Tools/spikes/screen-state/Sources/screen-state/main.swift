// Records, with millisecond timestamps: distributed lock/unlock/screensaver notifications,
// CGSessionCopyCurrentDictionary lock/console keys (polled 50 ms), IsSecureEventInputEnabled (100 ms),
// and CGEventSource idle seconds for two state IDs (500 ms). Usage: screen-state <seconds>
import Foundation
import AppKit
import CoreGraphics
import Carbon.HIToolbox

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "90") ?? 90
let t0 = ContinuousClock.now
func ms() -> Int64 { let d = ContinuousClock.now - t0; let (s, a) = d.components; return s * 1000 + a / 1_000_000_000_000_000 }
let lock = NSLock()
func emit(_ o: [String: Any]) {
    var o = o; o["t"] = ms()
    lock.lock(); defer { lock.unlock() }
    if let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8) { print(s); fflush(stdout) }
}
func session() -> (locked: Int?, onConsole: Int?) {
    guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return (nil, nil) }
    return (d["CGSSessionScreenIsLocked"] as? Int, d[kCGSessionOnConsoleKey as String] as? Int)
}
let names = ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked", "com.apple.screensaver.didstart", "com.apple.screensaver.didstop", "com.apple.sessionDidMoveOffConsole", "com.apple.sessionDidMoveOnConsole"]
let dnc = DistributedNotificationCenter.default()
for n in names {
    dnc.addObserver(forName: Notification.Name(n), object: nil, queue: nil) { _ in
        let s = session()
        emit(["kind": "notification", "name": n, "queryLocked": s.locked ?? -1, "queryOnConsole": s.onConsole ?? -1, "secureInput": IsSecureEventInputEnabled()])
    }
}
let wnc = NSWorkspace.shared.notificationCenter
for n in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification] {
    wnc.addObserver(forName: n, object: nil, queue: nil) { _ in emit(["kind": "workspace", "name": n.rawValue]) }
}
var lastLocked: Int? = -2, lastConsole: Int? = -2, lastSecure = false, lastAsleep: Bool? = nil
var lastIdleHID = -1.0, lastIdleCombined = -1.0
let start = session()
emit(["kind": "start", "seconds": seconds, "queryLocked": start.locked ?? -1, "queryOnConsole": start.onConsole ?? -1, "secureInput": IsSecureEventInputEnabled()])
let q = DispatchQueue(label: "spike.poll")
let timer = DispatchSource.makeTimerSource(queue: q)
var tick = 0
timer.schedule(deadline: .now(), repeating: .milliseconds(50))
timer.setEventHandler {
    tick += 1
    let s = session()
    if s.locked != lastLocked || s.onConsole != lastConsole {
        lastLocked = s.locked; lastConsole = s.onConsole
        emit(["kind": "query", "locked": s.locked ?? -1, "onConsole": s.onConsole ?? -1])
    }
    let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
    if asleep != lastAsleep { lastAsleep = asleep; emit(["kind": "display", "asleep": asleep]) }
    if tick % 2 == 0 {
        let sec = IsSecureEventInputEnabled()
        if sec != lastSecure { lastSecure = sec; emit(["kind": "secureInput", "enabled": sec]) }
    }
    if tick % 10 == 0 {
        let hid = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .null)
        let comb = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
        // log every 5 s, or whenever idle resets (activity)
        if tick % 100 == 0 || hid < lastIdleHID || comb < lastIdleCombined {
            emit(["kind": "idle", "hid": hid, "combined": comb])
        }
        lastIdleHID = hid; lastIdleCombined = comb
    }
}
timer.resume()
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
emit(["kind": "end"])
