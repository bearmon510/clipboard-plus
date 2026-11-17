import CoreBluetooth
import UIKit

/// CoreBluetooth is confined to the main queue, including state restoration.
@MainActor
final class PCSyncBluetooth: NSObject, PCSyncTransport, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "E8DB89CB-2BBF-48DD-8D0A-FB868C9A1472")
    static let toPC = CBUUID(string: "F4508CC7-393F-4288-8B72-A4A9A09D1D4D")
    static let toPad = CBUUID(string: "3A7ADCFC-CD62-4AF8-BF09-2C73023C5B83")
    var onEvent: ((PCSyncTransportEvent) -> Void)?
    private let log: (String) -> Void
    private let currentNow: () -> Date
    private let isAppActive: @MainActor () -> Bool
    private var central: CBCentralManager?
    private var policy = PCSyncReconnectPolicy()
    private var peers: [UUID: CBPeripheral] = [:]
    private var cancelling: Set<UUID> = []
    private var candidateStarted: [UUID: Date] = [:]
    private var active: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var verified = false
    private var ready = false
    private var discoveryStarted: Date?
    private var timer: Timer?

    init(
        log: @escaping (String) -> Void,
        now: @escaping () -> Date = Date.init,
        isAppActive: (@MainActor () -> Bool)? = nil
    ) {
        self.log = log
        self.currentNow = now
        self.isAppActive = isAppActive ?? { UIApplication.shared.applicationState == .active }
        super.init()
    }
    var canSend: Bool { ready && active?.canSendWriteWithoutResponse == true }

    func start(remembered: UUID?) {
        guard central == nil else { return }
        policy.setRemembered(remembered)
        NotificationCenter.default.addObserver(self, selector: #selector(foregroundChanged),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foregroundChanged),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        // This is intentionally the ONLY allocation site, reached after pairing is loaded/saved.
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "clipboardplus.pc-sync.central.v1"])
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        NotificationCenter.default.removeObserver(self)
        central?.stopScan()
        for peer in peers.values {
            peer.delegate = nil
            central?.cancelPeripheralConnection(peer)
        }
        central?.delegate = nil
        central = nil
        peers.removeAll(); cancelling.removeAll()
        candidateStarted.removeAll()
        policy.reset()
        active = nil; writeCharacteristic = nil; notifyCharacteristic = nil
        ready = false; verified = false; discoveryStarted = nil
    }

    @objc private func foregroundChanged() { seek() }
    private func tick() {
        let now = currentNow()
        // Only the authenticated, remembered address gets an unlimited pending connect.
        // A random advertiser must not occupy the second candidate slot indefinitely.
        for peer in peers.values where peer.identifier != policy.remembered && peer.state == .connecting {
            if let start = candidateStarted[peer.identifier], now.timeIntervalSince(start) > 20,
               !cancelling.contains(peer.identifier) {
                policy.recordCandidateTimeout(id: peer.identifier, now: now)
                cancelling.insert(peer.identifier)
                central?.cancelPeripheralConnection(peer)
                log("候補への接続待ちを終了; 次の候補を探す")
            }
        }
        if let start = discoveryStarted, now.timeIntervalSince(start) > 30 {
            log("切断; 理由=サービス・通知の準備期限")
            _ = reconnect(reason: .preAuthFailure)
        }
        seek()
    }

    private func seek() {
        guard let central, central.state == .poweredOn else { return }
        let now = currentNow()
        let activeApp = isAppActive()
        policy.prune(now: now)
        if verified { stopScan(); return }
        if active == nil, let remembered = policy.remembered {
            switch policy.connectAction(
                for: remembered,
                isCancelling: cancelling.contains(remembered),
                isActive: activeApp,
                now: now
            ) {
            case .wait:
                break
            case .connect(let startDelay):
                for peer in central.retrievePeripherals(withIdentifiers: [remembered]) {
                    connect(peer, startDelay: startDelay, now: now)
                }
            }
        }
        if activeApp {
            if !central.isScanning {
                central.scanForPeripherals(withServices: [Self.service],
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
                log("scan開始; サービス指定")
            }
        } else { stopScan() }
        onEvent?(.status(active != nil || peers.values.contains { $0.state == .connecting }
            ? .connecting : .searching))
    }
    private func stopScan() {
        if central?.isScanning == true { central?.stopScan(); log("scan停止") }
    }
    private func connect(_ peer: CBPeripheral, startDelay: TimeInterval?, now: Date) {
        guard active == nil, let central else { return }
        peers[peer.identifier] = peer
        peer.delegate = self
        if peer.state == .disconnected {
            // CoreBluetooth connect requests have no timeout, including in the background.
            let options: [String: Any]? = startDelay.map {
                [CBConnectPeripheralOptionStartDelayKey: NSNumber(value: $0)]
            }
            central.connect(peer, options: options)
            candidateStarted[peer.identifier] = now
            if let startDelay {
                log("接続待ち開始; 遅延秒=\(Int(ceil(startDelay)))")
            } else {
                log("接続待ち開始")
            }
        }
    }

    func authenticated(_ id: UUID) {
        guard active?.identifier == id else { return }
        verified = true
        policy.recordAuthenticated(id: id)
        stopScan()
        for peer in peers.values where peer.identifier != id && peer.state != .disconnected {
            cancelling.insert(peer.identifier)
            central?.cancelPeripheralConnection(peer)
        }
    }
    @discardableResult
    func reconnect(reason: PCSyncDisconnectReason) -> TimeInterval {
        guard let peer = active else { return 0 }
        let decision = policy.recordDisconnect(
            id: peer.identifier,
            reason: reason,
            isActive: isAppActive(),
            now: currentNow()
        )
        cancelling.insert(peer.identifier)
        clearActive()
        central?.cancelPeripheralConnection(peer)
        onEvent?(.disconnected(nextReconnectAt: decision.nextReconnectAt))
        seek()
        return decision.delay
    }
    private func clearActive() {
        active = nil; ready = false; verified = false; discoveryStarted = nil
        writeCharacteristic = nil; notifyCharacteristic = nil
    }
    func write(_ packet: Data) {
        guard canSend, let active, let writeCharacteristic else { return }
        active.writeValue(packet, for: writeCharacteristic, type: .withoutResponse)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Bluetooth状態=\(central.state.rawValue)")
        guard central.state == .poweredOn else {
            let hadSession = active != nil
            for peer in peers.values { peer.delegate = nil }
            peers.removeAll(); cancelling.removeAll(); candidateStarted.removeAll(); clearActive()
            if hadSession { onEvent?(.disconnected(nextReconnectAt: nil)) }
            switch central.state {
            case .unsupported: onEvent?(.status(.unsupported))
            case .unauthorized: onEvent?(.status(.unauthorized))
            default: onEvent?(.status(.bluetoothOff))
            }
            return
        }
        seek()
    }
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        log("状態復元; 件数=\(restored.count)")
        for peer in restored {
            peers[peer.identifier] = peer
            peer.delegate = self
            // Session keys/counters are intentionally not persisted. Cancel an existing link
            // so BOTH endpoints discard the old session before a fresh HELLO is sent.
            if peer.state == .connected || peer.identifier != policy.remembered {
                cancelling.insert(peer.identifier)
                central.cancelPeripheralConnection(peer)
            }
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let now = currentNow()
        guard active == nil,
              policy.connectAction(
                for: peripheral.identifier,
                isCancelling: cancelling.contains(peripheral.identifier),
                isActive: isAppActive(),
                now: now
              ) == .connect(startDelay: nil) else { return }
        // Keep the remembered, potentially stale address pending while trying a new one.
        guard peers.values.filter({ $0.state == .connecting }).count < 2 else { return }
        connect(peripheral, startDelay: nil, now: now)
        onEvent?(.status(.connecting))
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard active == nil,
              policy.canAcceptConnection(
                id: peripheral.identifier,
                isCancelling: cancelling.contains(peripheral.identifier),
                now: currentNow()
              ) else {
            cancelling.insert(peripheral.identifier)
            central.cancelPeripheralConnection(peripheral)
            return
        }
        active = peripheral; peers[peripheral.identifier] = peripheral
        candidateStarted.removeValue(forKey: peripheral.identifier)
        peripheral.delegate = self
        discoveryStarted = currentNow()
        log("接続成功; サービス確認開始")
        onEvent?(.status(.connecting))
        peripheral.discoverServices([Self.service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        lost(peripheral, error: error)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        lost(peripheral, error: error)
    }
    private func lost(_ peer: CBPeripheral, error: Error?) {
        // Never log NSError descriptions/userInfo, peripheral names, addresses or UUIDs.
        log("切断; 理由コード=\((error as NSError?)?.code ?? 0)")
        let wasCancelling = cancelling.remove(peer.identifier) != nil
        peers.removeValue(forKey: peer.identifier)
        candidateStarted.removeValue(forKey: peer.identifier)
        let wasActive = active?.identifier == peer.identifier
        var nextReconnectAt: Date?
        // Re-arm the OS-owned pending connection before this background callback returns,
        // using CBConnectPeripheralOptionStartDelayKey when backing off in the background.
        if !wasCancelling {
            let reason: PCSyncDisconnectReason = (wasActive && !verified) ? .preAuthFailure : .immediate
            nextReconnectAt = policy.recordDisconnect(
                id: peer.identifier,
                reason: reason,
                isActive: isAppActive(),
                now: currentNow()
            ).nextReconnectAt
        }
        if wasActive {
            clearActive()
            onEvent?(.disconnected(nextReconnectAt: nextReconnectAt))
        }
        seek()
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === active else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            log("切断; 理由=サービス確認失敗")
            let isTransient = error != nil || peripheral.identifier == policy.remembered
            _ = reconnect(reason: isTransient ? .preAuthFailure : .rejectTenMinutes)
            return
        }
        peripheral.discoverCharacteristics([Self.toPC, Self.toPad], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === active, service.uuid == Self.service else { return }
        guard error == nil,
              let write = service.characteristics?.first(where: { $0.uuid == Self.toPC }),
              let notify = service.characteristics?.first(where: { $0.uuid == Self.toPad }),
              write.properties.contains(.writeWithoutResponse), notify.properties.contains(.notify) else {
            log("切断; 理由=characteristic確認失敗")
            let isTransient = error != nil || peripheral.identifier == policy.remembered
            _ = reconnect(reason: isTransient ? .preAuthFailure : .rejectTenMinutes)
            return
        }
        writeCharacteristic = write; notifyCharacteristic = notify
        peripheral.setNotifyValue(true, for: notify)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === active, characteristic === notifyCharacteristic else { return }
        guard error == nil, characteristic.isNotifying else {
            log("切断; 理由=通知設定失敗"); _ = reconnect(reason: .preAuthFailure); return
        }
        guard !ready else { return }
        ready = true; discoveryStarted = nil
        let limit = min(512, peripheral.maximumWriteValueLength(for: .withoutResponse))
        log("MTU; writeWithoutResponse値上限=\(limit); 受信GATT値上限=512")
        // iOS exposes no negotiated notification limit. ATT attribute values are at most
        // 512 bytes; do not incorrectly use the independently reported write limit here.
        onEvent?(.ready(id: peripheral.identifier, writeLimit: limit, receiveLimit: 512))
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === active, characteristic === notifyCharacteristic, ready else { return }
        guard error == nil, let data = characteristic.value else {
            log("切断; 理由=通知受信失敗")
            _ = reconnect(reason: verified ? .immediate : .preAuthFailure)
            return
        }
        onEvent?(.packet(data))
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if peripheral === active { onEvent?(.writable) }
    }
    deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self) }
}
