// All timestamps come from the same physical HID clock. There is no hold timeout.
struct PhysicalKey: Hashable {
    let device: UInt64
    let cookie: UInt64
}

struct KeyReading {
    let key: PhysicalKey
    let isFn: Bool
    let down: Bool
    let timestamp: UInt64
}

struct ReleaseGesture {
    private(set) var key: PhysicalKey?
    private(set) var pressedAt: UInt64 = 0
    private(set) var releasedAt: UInt64?
    private(set) var generation: UInt64 = 0
    private(set) var cancellation = ""
    var isHeld: Bool { key != nil && releasedAt == nil }

    mutating func press(_ key: PhysicalKey, timestamp: UInt64, readings: [KeyReading]) {
        guard self.key == nil else {
            if self.key != key { cancellation = "anotherFn" }
            return
        }
        generation &+= 1
        self.key = key
        pressedAt = timestamp
        releasedAt = nil
        // A newer reading belongs to a later event, handled by otherKeyPressed.
        cancellation = readings.contains {
            $0.key != key && $0.down && $0.timestamp <= timestamp
        } ? "otherKeyAlreadyHeld" : ""
    }

    mutating func otherKeyPressed(timestamp: UInt64) {
        guard key != nil, timestamp >= pressedAt,
              releasedAt.map({ timestamp <= $0 }) ?? true else { return }
        cancellation = "keyChord"
    }

    mutating func release(_ key: PhysicalKey, timestamp: UInt64) -> UInt64? {
        guard self.key == key, releasedAt == nil, timestamp >= pressedAt else { return nil }
        releasedAt = timestamp
        return generation
    }

    // A run-loop turn lets queued HID chord events arrive before the action fires.
    mutating func finish(generation: UInt64) -> Bool? {
        guard self.generation == generation, releasedAt != nil else { return nil }
        let result = cancellation.isEmpty
        key = nil
        releasedAt = nil
        return result
    }

    mutating func reset() {
        generation &+= 1
        key = nil
        releasedAt = nil
        cancellation = ""
    }
}
