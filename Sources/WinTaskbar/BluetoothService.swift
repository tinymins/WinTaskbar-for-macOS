import Combine
import CoreBluetooth
import Foundation
import IOBluetooth

struct BluetoothDeviceInfo: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isConnected: Bool
}

private struct BluetoothSnapshot: Sendable {
    let available: Bool
    let poweredOn: Bool
    let devices: [BluetoothDeviceInfo]
}

// IOBluetooth's asynchronous callbacks need a run loop. Keep all native device
// access on this one thread; closeConnection is synchronous and can block.
private final class BluetoothWorker: @unchecked Sendable {
    static let shared = BluetoothWorker()

    private final class State: @unchecked Sendable {
        let ready = NSCondition()
        var runLoop: CFRunLoop?
        var callbacks: [UUID: ConnectionCallback] = [:]
    }

    private final class ConnectionCallback: NSObject {
        let completion: @Sendable (IOReturn) -> Void

        init(completion: @escaping @Sendable (IOReturn) -> Void) {
            self.completion = completion
        }

        @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
            completion(status)
        }
    }

    private let state = State()

    private init() {
        let state = state
        let thread = Thread {
            let port = Port()
            RunLoop.current.add(port, forMode: .default)
            state.ready.lock()
            state.runLoop = CFRunLoopGetCurrent()
            state.ready.signal()
            state.ready.unlock()
            CFRunLoopRun()
        }
        thread.name = "WinTaskbar Bluetooth"
        state.ready.lock()
        thread.start()
        while state.runLoop == nil { state.ready.wait() }
        state.ready.unlock()
    }

    private func perform<Result: Sendable>(
        _ work: @escaping @Sendable (State) -> Result
    ) async -> Result {
        await withCheckedContinuation { continuation in
            enqueue { state in continuation.resume(returning: work(state)) }
        }
    }

    private func enqueue(_ work: @escaping @Sendable (State) -> Void) {
        guard let runLoop = state.runLoop else { return }
        let state = state
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            autoreleasepool { work(state) }
        }
        CFRunLoopWakeUp(runLoop)
    }

    func snapshot() async -> BluetoothSnapshot {
        await perform { _ in
            let controller = IOBluetoothHostController.default()
            let poweredOn = controller?.powerState == kBluetoothHCIPowerStateON
            let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).compactMap { device in
                device.addressString.map {
                    BluetoothDeviceInfo(id: $0, name: device.nameOrAddress ?? $0, isConnected: device.isConnected())
                }
            }.sorted {
                if $0.isConnected != $1.isConnected { return $0.isConnected }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return BluetoothSnapshot(available: controller != nil, poweredOn: poweredOn, devices: devices)
        }
    }

    func connect(address: String, deadline: Date, completion: @escaping @Sendable (IOReturn) -> Void) async -> IOReturn {
        await perform { state in
            guard Date() < deadline else { return kIOReturnTimeout }
            guard let device = IOBluetoothDevice(addressString: address), device.isPaired() else {
                return kIOReturnNotFound
            }
            if device.isConnected() {
                completion(kIOReturnSuccess)
                return kIOReturnSuccess
            }
            let id = UUID()
            let callback = ConnectionCallback { [self] status in
                enqueue { state in state.callbacks[id] = nil }
                completion(status)
            }
            state.callbacks[id] = callback
            let result = device.openConnection(callback, withPageTimeout: 0x2000, authenticationRequired: true)
            if result != kIOReturnSuccess { state.callbacks[id] = nil }
            return result
        }
    }

    func disconnect(address: String, deadline: Date) async -> IOReturn {
        await perform { _ in
            guard Date() < deadline else { return kIOReturnTimeout }
            guard let device = IOBluetoothDevice(addressString: address) else { return kIOReturnNotFound }
            return device.isConnected() ? device.closeConnection() : kIOReturnSuccess
        }
    }
}

@MainActor
final class BluetoothService: NSObject, ObservableObject, CBCentralManagerDelegate {
    enum Availability {
        case accessRequired, denied, checking, off, on, unavailable
    }

    @Published private(set) var availability = Availability.accessRequired
    @Published private(set) var devices: [BluetoothDeviceInfo] = []
    @Published private(set) var pendingDeviceID: String?
    @Published private(set) var pendingConnect = false
    @Published private(set) var operationError: String?
    @Published private(set) var isOperationBusy = false

    var tileTitle: String {
        switch availability {
        case .accessRequired: NSLocalizedString("Bluetooth access required", comment: "")
        case .denied: NSLocalizedString("Bluetooth access is off", comment: "")
        case .checking: NSLocalizedString("Checking Bluetooth…", comment: "")
        case .off: NSLocalizedString("Bluetooth off", comment: "")
        case .unavailable: NSLocalizedString("Bluetooth unavailable", comment: "")
        case .on: devices.first(where: \.isConnected)?.name ?? NSLocalizedString("Not connected", comment: "")
        }
    }

    private var manager: CBCentralManager?
    private var pollTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var operationID: UUID?
    private var nativeOperationID: UUID?
    private var isVisible = false
    private var visibilityGeneration = 0
    private var refreshInProgress = false
    private var needsCompletionRefresh = false
    private var worker: BluetoothWorker { .shared }

    func start() {
        visibilityGeneration += 1
        isVisible = true
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        visibilityGeneration += 1
        isVisible = false
        pollTask?.cancel()
        pollTask = nil
    }

    func requestAccess() {
        if manager == nil {
            manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        Task { await refresh() }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard isVisible else { return }
            Task { await refresh() }
        }
    }

    private func refresh(allowHidden: Bool = false) async {
        guard isVisible || allowHidden else { return }
        if refreshInProgress {
            if allowHidden { needsCompletionRefresh = true }
            return
        }
        switch CBManager.authorization {
        case .notDetermined:
            availability = .accessRequired
            devices = []
            reconcileOperation()
            return
        case .denied, .restricted:
            availability = .denied
            devices = []
            reconcileOperation()
            return
        case .allowedAlways: break
        @unknown default:
            availability = .unavailable
            devices = []
            reconcileOperation()
            return
        }
        if availability == .accessRequired || availability == .denied { availability = .checking }
        refreshInProgress = true
        let generation = visibilityGeneration
        let snapshot = await worker.snapshot()
        refreshInProgress = false
        if needsCompletionRefresh {
            needsCompletionRefresh = false
            await refresh(allowHidden: true)
            return
        }
        guard allowHidden || (isVisible && generation == visibilityGeneration) else { return }
        availability = snapshot.available ? (snapshot.poweredOn ? .on : .off) : .unavailable
        devices = snapshot.devices
        reconcileOperation()
    }

    func toggleConnection(_ device: BluetoothDeviceInfo) {
        guard availability == .on, !isOperationBusy else { return }
        let id = UUID()
        operationID = id
        nativeOperationID = id
        isOperationBusy = true
        pendingDeviceID = device.id
        pendingConnect = !device.isConnected
        operationError = nil
        let deadline = Date().addingTimeInterval(20)
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, operationID == id else { return }
            finishOperation(error: NSLocalizedString("Bluetooth operation timed out. Check the device in System Settings.", comment: ""))
        }
        let connecting = pendingConnect
        Task { [weak self, worker] in
            let result: IOReturn
            if connecting {
                result = await worker.connect(address: device.id, deadline: deadline) { [weak self] status in
                    Task { @MainActor [weak self] in self?.connectionCompleted(id: id, status: status) }
                }
            } else {
                result = await worker.disconnect(address: device.id, deadline: deadline)
            }
            guard let self else { return }
            if !connecting || result != kIOReturnSuccess { finishNativeOperation(id: id) }
            guard operationID == id else {
                await refresh(allowHidden: true)
                return
            }
            if result != kIOReturnSuccess {
                finishOperation(error: operationFailure(connecting: connecting, status: result))
            }
            await refresh(allowHidden: true)
        }
    }

    private func connectionCompleted(id: UUID, status: IOReturn) {
        finishNativeOperation(id: id)
        guard operationID == id else {
            Task { await refresh(allowHidden: true) }
            return
        }
        if status != kIOReturnSuccess {
            finishOperation(error: operationFailure(connecting: true, status: status))
        }
        Task { await refresh(allowHidden: true) }
    }

    private func finishNativeOperation(id: UUID) {
        guard nativeOperationID == id else { return }
        nativeOperationID = nil
        isOperationBusy = operationID != nil
    }

    private func operationFailure(connecting: Bool, status: IOReturn) -> String {
        let format = NSLocalizedString(
            connecting ? "Could not connect the Bluetooth device (error %d)." : "Could not disconnect the Bluetooth device (error %d).",
            comment: ""
        )
        return String(format: format, status)
    }

    private func reconcileOperation() {
        guard let pendingDeviceID else { return }
        if let device = devices.first(where: { $0.id == pendingDeviceID }), device.isConnected == pendingConnect {
            finishOperation(error: nil)
        } else if availability != .on {
            finishOperation(error: NSLocalizedString("Bluetooth is unavailable. Check Bluetooth in System Settings.", comment: ""))
        }
    }

    private func finishOperation(error: String?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        operationID = nil
        isOperationBusy = nativeOperationID != nil
        pendingDeviceID = nil
        operationError = error
    }
}
