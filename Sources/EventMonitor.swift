import AppKit
import Carbon
import IOKit.hid

final class MonitorStatistics {
    var fnPresses = 0
    var fnReleases = 0
    var acceptedGestures = 0
    var chordsCancelled = 0
    var interruptedGestures = 0
    var languageChanges = 0
    var switchFailures = 0
    var lastReason = "starting"
    var lastFnEventAt = ""
}

final class EventMonitor {
    private struct Element {
        let device: IOHIDDevice
        let value: IOHIDElement
        let isFn: Bool
    }
    private var manager: IOHIDManager?
    private var elements: [PhysicalKey: Element] = [:]
    private var devices: [UInt64: Set<PhysicalKey>] = [:]
    private var observedFnTime: [PhysicalKey: UInt64] = [:]
    private var unobservedSince: [PhysicalKey: TimeInterval] = [:]
    private var blockedUntilRelease: Set<PhysicalKey> = []
    private var gesture = ReleaseGesture()
    private var failurePending = false
    private let statistics: MonitorStatistics
    var onFailure: ((Error) -> Void)?
    var onSwitch: (() -> Void)?
    var onChange: (() -> Void)?
    var fnElementCount: Int { elements.values.filter(\.isFn).count }
    var isOpen: Bool { manager != nil && !failurePending }

    init(statistics: MonitorStatistics = MonitorStatistics()) { self.statistics = statistics }
    deinit { stop() }

    func start() throws {
        guard manager == nil else { return }
        failurePending = false
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        self.manager = manager
        IOHIDManagerSetDeviceMatching(manager, nil)
        let matching: [[String: Int]] = [
            [kIOHIDElementUsagePageKey: 7],
            [kIOHIDElementUsagePageKey: 12],
            [kIOHIDElementUsagePageKey: 0xFF, kIOHIDElementUsageKey: 3]
        ]
        IOHIDManagerSetInputValueMatchingMultiple(manager, matching as CFArray)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard let context else { return }
            let monitor = Unmanaged<EventMonitor>.fromOpaque(context).takeUnretainedValue()
            if result == kIOReturnSuccess { monitor.receive(value) }
            else { monitor.fail(SetupError.message("Ошибка потока клавиатуры: \(result).")) }
        }, pointer)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard let context, result == kIOReturnSuccess else { return }
            let monitor = Unmanaged<EventMonitor>.fromOpaque(context).takeUnretainedValue()
            do { try monitor.add(device) } catch { monitor.fail(error) }
        }, pointer)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<EventMonitor>.fromOpaque(context).takeUnretainedValue().remove(device)
        }, pointer)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        do {
            let result = IOHIDManagerOpen(manager, 0)
            guard result == kIOReturnSuccess else {
                throw SetupError.message("Нет доступа к физической клавиатуре: \(result).")
            }
            for device in IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [] { try add(device) }
            guard fnElementCount > 0 else { throw SetupError.message("Физическая клавиша Fn не найдена.") }
            try checkHealth()
        } catch { stop(); throw error }
    }

    func stop() {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerClose(manager, 0)
        }
        manager = nil
        interrupt(reason: "monitorStopped")
        elements.removeAll()
        devices.removeAll()
        observedFnTime.removeAll()
        unobservedSince.removeAll()
        blockedUntilRelease.removeAll()
    }

    func reset() { interrupt(reason: "reset") }

    func checkHealth() throws {
        guard isOpen, fnElementCount > 0 else { throw SetupError.message("Обработчик Fn недоступен.") }
        let now = ProcessInfo.processInfo.systemUptime
        for (key, element) in elements where element.isFn {
            let reading = try read(key, element)
            if reading.timestamp > (observedFnTime[key] ?? 0) {
                // Allow queued callbacks to run; a persistent mismatch means delivery was lost.
                if let since = unobservedSince[key], now - since >= 0.15 {
                    throw SetupError.message("Прервалась доставка событий Fn; обработчик перезапускается.")
                }
                if unobservedSince[key] == nil { unobservedSince[key] = now }
            } else { unobservedSince.removeValue(forKey: key) }
        }
        if gesture.isHeld {
            for reading in try snapshot() where !reading.isFn && reading.down {
                gesture.otherKeyPressed(timestamp: reading.timestamp)
            }
        }
    }

    private static func deviceID(_ device: IOHIDDevice) -> UInt64 {
        UInt64(UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque()))
    }

    private static func physicalKey(_ element: IOHIDElement) -> PhysicalKey {
        PhysicalKey(device: deviceID(IOHIDElementGetDevice(element)), cookie: UInt64(IOHIDElementGetCookie(element)))
    }

    private static func relevant(_ element: IOHIDElement) -> Bool {
        let type = IOHIDElementGetType(element).rawValue
        guard (1...4).contains(type), !IOHIDElementIsRelative(element),
              IOHIDElementGetLogicalMin(element) == 0, IOHIDElementGetLogicalMax(element) == 1 else { return false }
        let page = IOHIDElementGetUsagePage(element), usage = IOHIDElementGetUsage(element)
        return (page == 7 && (4...0xE7).contains(usage)) || page == 12 || (page == 255 && usage == 3)
    }

    private func add(_ device: IOHIDDevice) throws {
        let id = Self.deviceID(device)
        guard devices[id] == nil else { return }
        let list = (IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement] ?? []).filter(Self.relevant)
        // Ignore unrelated devices with consumer controls (for example a mouse).
        guard list.contains(where: { IOHIDElementGetUsagePage($0) == 7 || IOHIDElementGetUsagePage($0) == 255 }) else { return }
        interrupt(reason: "keyboardConnected")
        devices[id] = []
        for value in list {
            let key = Self.physicalKey(value)
            let isFn = IOHIDElementGetUsagePage(value) == 255
            let element = Element(device: device, value: value, isFn: isFn)
            elements[key] = element
            devices[id]?.insert(key)
            if isFn {
                let reading = try read(key, element)
                observedFnTime[key] = reading.timestamp
                if reading.down { blockedUntilRelease.insert(key) }
            }
        }
    }

    private func remove(_ device: IOHIDDevice) {
        guard let keys = devices.removeValue(forKey: Self.deviceID(device)) else { return }
        interrupt(reason: "keyboardDisconnected")
        for key in keys {
            elements.removeValue(forKey: key)
            observedFnTime.removeValue(forKey: key)
            unobservedSince.removeValue(forKey: key)
            blockedUntilRelease.remove(key)
        }
        onChange?()
    }

    private func read(_ key: PhysicalKey, _ element: Element) throws -> KeyReading {
        try withUnsafeTemporaryAllocation(of: Unmanaged<IOHIDValue>.self, capacity: 1) { buffer in
            let result = IOHIDDeviceGetValue(element.device, element.value, buffer.baseAddress!)
            guard result == kIOReturnSuccess else {
                throw SetupError.message("Не удалось прочитать состояние клавиатуры: \(result).")
            }
            let value = buffer[0].takeUnretainedValue()
            return KeyReading(key: key, isFn: element.isFn, down: IOHIDValueGetIntegerValue(value) != 0,
                              timestamp: IOHIDValueGetTimeStamp(value))
        }
    }

    private func snapshot() throws -> [KeyReading] { try elements.map { try read($0.key, $0.value) } }

    private func receive(_ value: IOHIDValue) {
        guard !failurePending else { return }
        // Never carry a partial gesture through a protected-input boundary.
        guard !IsSecureEventInputEnabled() else { interrupt(reason: "secureInput"); return }
        let key = Self.physicalKey(IOHIDValueGetElement(value))
        guard let element = elements[key] else { return }
        let down = IOHIDValueGetIntegerValue(value) != 0
        let timestamp = IOHIDValueGetTimeStamp(value)
        if !element.isFn {
            if down { gesture.otherKeyPressed(timestamp: timestamp) }
            return
        }
        observedFnTime[key] = max(observedFnTime[key] ?? 0, timestamp)
        unobservedSince.removeValue(forKey: key)
        statistics.lastFnEventAt = ISO8601DateFormatter().string(from: Date())
        if blockedUntilRelease.contains(key) {
            if !down { blockedUntilRelease.remove(key) }
            statistics.lastReason = "fnHeldDuringRestart"
            onChange?()
            return
        }
        if down {
            statistics.fnPresses += 1
            if let generation = gesture.releasedAt.map({ _ in gesture.generation }) { finish(generation) }
            do { gesture.press(key, timestamp: timestamp, readings: try snapshot()) }
            catch { fail(error); return }
            statistics.lastReason = "fnPressed"
        } else {
            statistics.fnReleases += 1
            if let generation = gesture.release(key, timestamp: timestamp) {
                DispatchQueue.main.async { [weak self] in self?.finish(generation) }
            } else { statistics.lastReason = "releaseWithoutPress" }
        }
        onChange?()
    }

    private func finish(_ generation: UInt64) {
        let reason = gesture.cancellation
        guard let accepted = gesture.finish(generation: generation) else { return }
        if accepted {
            statistics.acceptedGestures += 1
            statistics.lastReason = "switchRequested"
            onSwitch?()
        } else {
            statistics.chordsCancelled += 1
            statistics.lastReason = reason
        }
        onChange?()
    }

    private func interrupt(reason: String) {
        if gesture.key != nil { statistics.interruptedGestures += 1 }
        gesture.reset()
        statistics.lastReason = reason
    }

    private func fail(_ error: Error) {
        guard !failurePending else { return }
        failurePending = true
        interrupt(reason: "inputFailure")
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }
}
