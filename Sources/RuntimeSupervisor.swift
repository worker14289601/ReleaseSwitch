import Foundation

final class RuntimeSupervisor {
    enum State: Equatable {
        case waitingForAccess, sleeping, protectedInput, running, recovering(String)
    }
    private let start: () throws -> Void
    private let stop: () -> Void
    private let check: () throws -> Void
    private(set) var running = false
    private(set) var state: State = .waitingForAccess
    private(set) var restarts = 0
    private(set) var lastRecovery = ""

    init(start: @escaping () throws -> Void, stop: @escaping () -> Void,
         check: @escaping () throws -> Void) {
        self.start = start
        self.stop = stop
        self.check = check
    }

    // Called throughout the application's lifetime, including after a failure.
    func tick(access: Bool, secureInput: Bool, suspended: Bool) {
        if suspended { suspend(.sleeping); return }
        if !access { suspend(.waitingForAccess); return }
        if secureInput { suspend(.protectedInput); return }
        do {
            if running {
                try check()
            } else {
                try start()
                running = true
            }
            state = .running
        } catch { restart(reason: error.localizedDescription) }
    }

    func restart(reason: String) {
        stop()
        running = false
        restarts += 1
        lastRecovery = reason
        state = .recovering(reason)
    }

    func suspend(_ state: State) {
        if running { stop() }
        running = false
        self.state = state
    }
}
