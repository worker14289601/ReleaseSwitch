import AppKit
import Carbon

// Real HID lifecycle check. It never selects a language or posts keyboard events.
@main struct MonitorHarness {
    static func main() throws {
        let statistics = MonitorStatistics()
        let monitor = EventMonitor(statistics: statistics)
        var switches = 0
        var failure: Error?
        monitor.onSwitch = { switches += 1 }
        monitor.onFailure = { failure = $0 }
        for cycle in 1...3 {
            try monitor.start()
            precondition(monitor.isOpen && monitor.fnElementCount > 0)
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                try monitor.checkHealth()
                if let failure { throw failure }
            }
            print("PASS: real HID lifecycle cycle \(cycle); Fn elements=\(monitor.fnElementCount)")
            monitor.stop()
            precondition(!monitor.isOpen && monitor.fnElementCount == 0)
        }
        print("PASS: no language changes requested from this harness; observed gestures=\(switches)")
    }
}
