import Foundation

struct SourceAccess {
    var enabledIDs: () throws -> [String]
    var currentID: () throws -> String
    var select: (String) throws -> Void
}

final class LanguageSwitcher {
    typealias Completion = (Result<String, Error>) -> Void
    private let access: SourceAccess
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var requests: [Completion] = []
    private var busy = false
    private var generation: UInt64 = 0

    init(access: SourceAccess, schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = {
        delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }) {
        self.access = access
        self.schedule = schedule
    }

    func request(_ completion: @escaping Completion) {
        requests.append(completion)
        if !busy { startNext() }
    }

    func cancel() {
        generation &+= 1
        requests.removeAll()
        busy = false
    }

    private func startNext() {
        guard !requests.isEmpty else { busy = false; return }
        busy = true
        generation &+= 1
        let token = generation
        do {
            var seen: Set<String> = []
            let ids = try access.enabledIDs().filter { !$0.isEmpty && seen.insert($0).inserted }
            guard ids.count > 1 else {
                throw SetupError.message("Для переключения нужны две доступные раскладки.")
            }
            let current = try access.currentID()
            let index = ids.firstIndex(of: current) ?? -1
            let target = ids[(index + 1) % ids.count]
            try access.select(target)
            verify(target: target, generation: token, attempt: 0)
        } catch { finish(.failure(error), generation: token) }
    }

    private func verify(target: String, generation token: UInt64, attempt: Int) {
        guard token == generation, busy else { return }
        do {
            if try access.currentID() == target {
                finish(.success(target), generation: token)
            } else if attempt < 3 {
                schedule(0.05) { [weak self] in
                    self?.verify(target: target, generation: token, attempt: attempt + 1)
                }
            } else {
                throw SetupError.message("macOS не подтвердила смену раскладки.")
            }
        } catch { finish(.failure(error), generation: token) }
    }

    private func finish(_ result: Result<String, Error>, generation token: UInt64) {
        guard token == generation, !requests.isEmpty else { return }
        let completion = requests.removeFirst()
        // Keep busy while the callback runs: another request must join the queue.
        completion(result)
        guard token == generation else { return }
        startNext()
    }
}
