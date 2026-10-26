import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ description: String) {
    checks += 1
    guard condition() else { fatalError(description) }
}
let fn = PhysicalKey(device: 1, cookie: 1)
let other = PhysicalKey(device: 1, cookie: 2)
let secondFn = PhysicalKey(device: 2, cookie: 1)
func reading(_ down: Bool, _ time: UInt64, key: PhysicalKey = other) -> KeyReading {
    KeyReading(key: key, isFn: key == fn || key == secondFn, down: down, timestamp: time)
}
func release(_ gesture: inout ReleaseGesture, _ time: UInt64) -> Bool? {
    guard let token = gesture.release(fn, timestamp: time) else { return nil }
    return gesture.finish(generation: token)
}

do {
    var gesture = ReleaseGesture()
    gesture.press(fn, timestamp: 10, readings: [])
    check(gesture.isHeld, "Fn down must not fire")
    check(release(&gesture, 10) == true, "A fast standalone release must fire")
    check(release(&gesture, 11) == nil, "A duplicate release must not fire")
    gesture.press(fn, timestamp: 20, readings: [])
    check(release(&gesture, UInt64.max - 1) == true, "Long holds have no upper limit")
}
do {
    var gesture = ReleaseGesture()
    gesture.press(fn, timestamp: 10, readings: [reading(true, 5)])
    check(release(&gesture, 20) == false, "A physically held key cancels Fn")
    // No key-up callback is delivered. The next fresh physical reading is enough.
    gesture.press(fn, timestamp: 30, readings: [reading(false, 25)])
    check(release(&gesture, 40) == true, "A missed key-up must not poison the next gesture")
    gesture.press(fn, timestamp: 50, readings: [reading(false, 45)])
    check(release(&gesture, 60) == true, "Recovery persists for subsequent presses")
}
do {
    var gesture = ReleaseGesture()
    gesture.press(fn, timestamp: 10, readings: [])
    gesture.otherKeyPressed(timestamp: 15)
    check(release(&gesture, 20) == false, "Fn plus a letter/modifier/media key cancels")
    gesture.press(fn, timestamp: 30, readings: [])
    gesture.press(fn, timestamp: 31, readings: [])
    check(release(&gesture, 40) == true, "Duplicate down values do not create another gesture")
}
do {
    var gesture = ReleaseGesture()
    gesture.press(fn, timestamp: 10, readings: [])
    let token = gesture.release(fn, timestamp: 20)!
    gesture.otherKeyPressed(timestamp: 15)
    check(gesture.finish(generation: token) == false, "A queued chord event before release still cancels")
    gesture.press(fn, timestamp: 30, readings: [reading(true, 45)])
    let next = gesture.release(fn, timestamp: 40)!
    gesture.otherKeyPressed(timestamp: 45)
    check(gesture.finish(generation: next) == true, "Typing after physical release must not cancel Fn")
    gesture.press(fn, timestamp: 50, readings: [])
    gesture.otherKeyPressed(timestamp: 49)
    check(release(&gesture, 60) == true, "A late event from before Fn down is ignored")
}
do {
    var gesture = ReleaseGesture()
    gesture.press(fn, timestamp: 10, readings: [])
    let old = gesture.release(fn, timestamp: 20)!
    gesture.reset()
    check(gesture.finish(generation: old) == nil, "Reset invalidates a queued release")
    check(release(&gesture, 30) == nil, "Wake/reconnect must not turn an orphan release into a tap")
    gesture.press(fn, timestamp: 40, readings: [])
    check(gesture.finish(generation: old) == nil, "An old completion cannot finish a new gesture")
    check(release(&gesture, 50) == true, "A fresh gesture works after interruption")
    gesture.press(fn, timestamp: 60, readings: [])
    gesture.otherKeyPressed(timestamp: 65)
    gesture.reset() // Simulate a missed Fn-up followed by monitor recovery.
    gesture.press(fn, timestamp: 70, readings: [])
    check(release(&gesture, 80) == true, "A missed Fn-up is cleared by recovery")
}
do {
    var gesture = ReleaseGesture()
    gesture.press(fn, timestamp: 10, readings: [reading(true, 5, key: secondFn)])
    check(release(&gesture, 20) == false, "Another device's held Fn is a chord")
    gesture.press(fn, timestamp: 30, readings: [])
    gesture.press(secondFn, timestamp: 31, readings: [])
    check(gesture.release(secondFn, timestamp: 32) == nil, "Different devices with the same cookie stay distinct")
    check(release(&gesture, 40) == false, "Two simultaneous Fn keys cancel the owner")
    gesture.press(fn, timestamp: 50, readings: [])
    check(gesture.release(fn, timestamp: 49) == nil, "Out-of-order releases cannot finish a newer press")
    check(release(&gesture, 60) == true, "The valid release still works")
}

final class VirtualClock {
    var jobs: [(Double, Int, () -> Void)] = []
    var now = 0.0
    var order = 0
    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        order += 1; jobs.append((now + delay, order, work))
    }
    func drain() {
        var limit = 1000
        while !jobs.isEmpty {
            limit -= 1; precondition(limit > 0, "Unbounded retry loop")
            jobs.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            let next = jobs.removeFirst(); now = next.0; next.2()
        }
    }
}
final class FakeSources {
    var ids = ["A", "B"]
    var current = "A"
    var selected: [String] = []
    var listFails = false
    var selectionFails = false
    var confirm = true
    var delay = 0.0
    let clock = VirtualClock()
    lazy var switcher = LanguageSwitcher(access: SourceAccess(
        enabledIDs: { [unowned self] in
            if self.listFails { throw SetupError.message("list unavailable") }
            return self.ids
        },
        currentID: { [unowned self] in self.current },
        select: { [unowned self] id in
            if self.selectionFails { throw SetupError.message("select failed") }
            self.selected.append(id)
            if self.confirm {
                if self.delay == 0 { self.current = id }
                else { self.clock.schedule(self.delay) { self.current = id } }
            }
        }), schedule: { [unowned self] delay, work in self.clock.schedule(delay, work) })
}
func succeeded(_ result: Result<String, Error>) -> Bool {
    if case .success = result { return true }; return false
}
do {
    let source = FakeSources()
    var results: [Bool] = []
    source.switcher.request { results.append(succeeded($0)) }
    check(results == [true] && source.current == "B", "An immediate confirmed switch succeeds")
    source.switcher.request { results.append(succeeded($0)) }
    check(results == [true, true] && source.current == "A", "The next switch uses the actual current source")
}
for ids in [[], ["A"], ["A", "A"], ["", "A"]] {
    let source = FakeSources(); source.ids = ids
    var results: [Bool] = []
    source.switcher.request { results.append(succeeded($0)) }
    check(results == [false] && source.selected.isEmpty, "Unavailable sources must not count as success: \(ids)")
}
do {
    let source = FakeSources(); source.confirm = false
    var results: [Bool] = []
    source.switcher.request { results.append(succeeded($0)) }
    check(results.isEmpty, "An unconfirmed switch is pending, not successful")
    source.clock.drain()
    check(results == [false], "A no-op selection reports failure after bounded verification")
    source.confirm = true
    source.switcher.request { results.append(succeeded($0)) }
    check(results == [false, true], "A failed switch must not prevent the next request")
}
do {
    let source = FakeSources(); source.delay = 0.07
    var results: [Bool] = []
    source.switcher.request { results.append(succeeded($0)) }
    source.switcher.request { results.append(succeeded($0)) }
    check(source.selected == ["B"], "Rapid taps queue while macOS confirms the first switch")
    source.clock.drain()
    check(source.selected == ["B", "A"] && results == [true, true], "Rapid taps confirm two distinct transitions")
}
do {
    let source = FakeSources(); source.confirm = false
    var results: [Bool] = []
    source.switcher.request { results.append(succeeded($0)) }
    source.switcher.request { results.append(succeeded($0)) }
    source.switcher.cancel()
    source.clock.drain()
    check(results.isEmpty, "Sleep/secure-input recovery discards stale completions")
    source.confirm = true
    source.switcher.request { results.append(succeeded($0)) }
    check(results == [true], "Switching resumes after cancellation")
}
do {
    let source = FakeSources(); source.listFails = true
    var results: [Bool] = []
    source.switcher.request { results.append(succeeded($0)) }
    check(results == [false], "Source enumeration errors reach the caller")
    source.listFails = false; source.selectionFails = true
    source.switcher.request { results.append(succeeded($0)) }
    check(results == [false, false], "Selection errors reach the caller")
    source.selectionFails = false
    source.switcher.request { results.append(succeeded($0)) }
    check(results == [false, false, true], "API errors do not wedge the request queue")
}
do {
    let source = FakeSources()
    var count = 0
    source.switcher.request { result in
        if succeeded(result) { count += 1 }
        source.switcher.request { if succeeded($0) { count += 1 } }
    }
    check(count == 2 && source.selected == ["B", "A"], "A callback can queue another switch safely")
}

do {
    var starts = 0, stops = 0, healthChecks = 0
    var startFails = false, healthFails = false
    let supervisor = RuntimeSupervisor(start: {
        starts += 1
        if startFails { throw SetupError.message("start failed") }
    }, stop: { stops += 1 }, check: {
        healthChecks += 1
        if healthFails { throw SetupError.message("stream lost") }
    })
    func tick(_ access: Bool = true, _ secure: Bool = false, _ sleep: Bool = false) {
        supervisor.tick(access: access, secureInput: secure, suspended: sleep)
    }
    tick(false)
    check(starts == 0 && !supervisor.running, "No monitor starts without permission")
    tick()
    check(starts == 1 && supervisor.running, "Permission enables monitoring")
    tick(); tick()
    check(healthChecks == 2 && starts == 1, "Health checks continue after successful startup")
    healthFails = true; tick()
    check(!supervisor.running && stops == 1, "A broken stream is stopped instead of marked active")
    check(supervisor.lastRecovery == "stream lost", "The recovery reason is retained")
    healthFails = false; tick()
    check(starts == 2 && supervisor.running, "The next tick recreates a broken monitor")
    tick(true, true)
    check(supervisor.state == .protectedInput && !supervisor.running, "Secure input stops partial gestures")
    tick(true, true)
    check(starts == 2, "Protected input does not create a restart loop")
    tick()
    check(starts == 3 && supervisor.running, "Monitoring is recreated after protected input ends")
    tick(true, false, true)
    check(supervisor.state == .sleeping && !supervisor.running, "Sleep stops the old monitor")
    tick()
    check(starts == 4 && supervisor.running, "Wake creates a fresh monitor")
    tick(false)
    check(supervisor.state == .waitingForAccess && !supervisor.running, "Revoking permission updates the active state")
    startFails = true; tick()
    check(!supervisor.running, "A failed restart cannot advertise success")
    startFails = false; tick()
    check(supervisor.running && starts == 6, "A startup failure is retried on a later tick")
    supervisor.restart(reason: "device removed"); tick()
    check(supervisor.running && starts == 7, "Device removal uses the same automatic recovery path")
}
print("PASS: \(checks) regression checks")
