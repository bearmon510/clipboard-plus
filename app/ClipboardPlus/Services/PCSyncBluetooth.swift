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
    private enum ScanMode { case foreground, background }
    private var central: CBCentralManager?
    private var policy = PCSyncReconnectPolicy()
    private var tracker = PCSyncConnectionTracker()
    private var peers: [UUID: CBPeripheral] = [:]
    private var candidateStarted: [UUID: Date] = [:]
    private var active: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var verified = false
    private var ready = false
    private var discoveryStarted: Date?
    private var activeScanMode: ScanMode?
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
        activeScanMode = nil
        for peer in peers.values {
            peer.delegate = nil
            central?.cancelPeripheralConnection(peer)
        }
        central?.delegate = nil
        central = nil
        peers.removeAll(); tracker.resetAll()
        candidateStarted.removeAll()
        policy.reset()
        active = nil; writeCharacteristic = nil; notifyCharacteristic = nil
        ready = false; verified = false; discoveryStarted = nil
    }

    @objc private func foregroundChanged() { seek() }
    private func tick() {
        let now = currentNow()
        tracker.pruneCancelling(now: now)
        // Only the authenticated, remembered address gets an unlimited pending connect.
        // A random advertiser must not occupy the second candidate slot indefinitely.
        for peer in Array(peers.values) where peer.identifier != policy.remembered &&
            (peer.state == .connecting || tracker.isReserved(peer.identifier)) {
            if let start = candidateStarted[peer.identifier], now.timeIntervalSince(start) > 20,
               !tracker.isCancelling(peer.identifier, now: now) {
                policy.recordCandidateTimeout(id: peer.identifier, now: now)
                if peer.state != .disconnected {
                    tracker.markCancelling(peer.identifier, now: now)
                    central?.cancelPeripheralConnection(peer)
                } else {
                    _ = tracker.finishDisconnect(peer.identifier)
                    peers.removeValue(forKey: peer.identifier)
                    candidateStarted.removeValue(forKey: peer.identifier)
                }
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
        var needsBackgroundScan = false
        if active == nil, let remembered = policy.remembered {
            let targetPeer = central.retrievePeripherals(withIdentifiers: [remembered]).first ?? peers[remembered]
            let snapshot = targetPeer.map { PCSyncPeerSnapshot(id: $0.identifier, state: Self.peerState($0.state)) }
            let plan = tracker.rememberedSeekPlan(
                peer: snapshot,
                policy: policy,
                isActiveApp: activeApp,
                now: now
            )
            needsBackgroundScan = plan.needsBackgroundScan
            if let peer = targetPeer {
                executeDecision(plan.decision, for: peer, central: central, now: now)
            }
        }
        if activeApp {
            startScan(mode: .foreground)
        } else if needsBackgroundScan {
            startScan(mode: .background)
        } else {
            stopScan()
        }
        updateStatus()
    }
    private func startScan(mode: ScanMode) {
        guard let central else { return }
        if central.isScanning, activeScanMode == mode { return }
        if central.isScanning { central.stopScan() }
        let options: [String: Any]? = mode == .foreground
            ? [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            : nil
        central.scanForPeripherals(withServices: [Self.service], options: options)
        activeScanMode = mode
        log(mode == .foreground ? "scan開始; サービス指定" : "裏scan開始; サービス指定")
    }
    private func stopScan() {
        activeScanMode = nil
        if central?.isScanning == true { central?.stopScan(); log("scan停止") }
    }
    private func updateStatus() {
        let connecting = active != nil || peers.values.contains { $0.state == .connecting }
        onEvent?(.status(connecting ? .connecting : .searching))
    }
    private func executeDecision(
        _ decision: PCSyncReservationDecision,
        for peer: CBPeripheral,
        central: CBCentralManager,
        now: Date
    ) {
        switch decision {
        case .none:
            break
        case .connect(let startDelay):
            connect(peer, startDelay: startDelay, central: central, now: now)
        case .replaceExpiredDelayConnect:
            central.cancelPeripheralConnection(peer)
            log("期限切れの遅延付き接続予約を取り消し; 遅延なしで再予約")
            connect(peer, startDelay: nil, central: central, now: now)
        case .cancelExpiredDelay:
            peers[peer.identifier] = peer
            peer.delegate = self
            central.cancelPeripheralConnection(peer)
            log("期限切れの遅延付き接続予約を取り消し")
        case .cancelUnexpectedConnection:
            peers[peer.identifier] = peer
            peer.delegate = self
            central.cancelPeripheralConnection(peer)
            log("未認証の既存接続を取り消し")
        }
    }
    private func connect(_ peer: CBPeripheral, startDelay: Int?, central: CBCentralManager, now: Date) {
        guard active == nil else { return }
        peers[peer.identifier] = peer
        peer.delegate = self
        // CoreBluetooth connect requests have no timeout, including in the background.
        let options: [String: Any]? = startDelay.map {
            [CBConnectPeripheralOptionStartDelayKey: NSNumber(value: $0)]
        }
        central.connect(peer, options: options)
        candidateStarted[peer.identifier] = now
        if let startDelay {
            log("接続待ち開始; 遅延秒=\(startDelay)")
        } else {
            log("接続待ち開始")
        }
    }

    func authenticated(_ id: UUID) {
        guard active?.identifier == id else { return }
        let now = currentNow()
        verified = true
        policy.recordAuthenticated(id: id)
        stopScan()
        for peer in peers.values where peer.identifier != id && peer.state != .disconnected {
            tracker.markCancelling(peer.identifier, now: now)
            central?.cancelPeripheralConnection(peer)
        }
    }
    @discardableResult
    func reconnect(reason: PCSyncDisconnectReason) -> TimeInterval {
        guard let peer = active else { return 0 }
        let now = currentNow()
        let decision = policy.recordDisconnect(
            id: peer.identifier,
            reason: reason,
            isActive: isAppActive(),
            now: now
        )
        if peer.state != .disconnected {
            tracker.markCancelling(peer.identifier, now: now)
            central?.cancelPeripheralConnection(peer)
        } else {
            _ = tracker.finishDisconnect(peer.identifier)
            peers.removeValue(forKey: peer.identifier)
            candidateStarted.removeValue(forKey: peer.identifier)
        }
        clearActive()
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
            if central.state != .unknown {
                let hadSession = active != nil
                for peer in peers.values { peer.delegate = nil }
                peers.removeAll(); tracker.resetAll(); candidateStarted.removeAll(); clearActive()
                activeScanMode = nil
                if hadSession { onEvent?(.disconnected(nextReconnectAt: nil)) }
            }
            switch central.state {
            case .unsupported: onEvent?(.status(.unsupported))
            case .unauthorized: onEvent?(.status(.unauthorized))
            default: onEvent?(.status(.bluetoothOff))
            }
            return
        }
        let now = currentNow()
        let snapshots = peers.values.map { PCSyncPeerSnapshot(id: $0.identifier, state: Self.peerState($0.state)) }
        let actions = tracker.handlePoweredOn(
            restoredPeers: snapshots,
            remembered: policy.remembered,
            activeId: active?.identifier,
            now: now
        )
        for action in actions {
            switch action {
            case .cancel(let id):
                // Session keys/counters are intentionally not persisted. Cancel an existing link
                // so BOTH endpoints discard the old session before a fresh HELLO is sent.
                if let peer = peers[id] {
                    central.cancelPeripheralConnection(peer)
                }
            case .trackCancelling, .keepReserved:
                break
            case .remove(let id):
                if let peer = peers.removeValue(forKey: id) { peer.delegate = nil }
                candidateStarted.removeValue(forKey: id)
            }
        }
        seek()
    }
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        log("状態復元; 件数=\(restored.count)")
        for peer in restored {
            peers[peer.identifier] = peer
            peer.delegate = self
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let now = currentNow()
        let activeApp = isAppActive()
        guard active == nil else { return }
        // Keep the remembered, potentially stale address pending while trying a new one.
        let pendingIds = Set(peers.values.filter { $0.state == .connecting }.map(\.identifier))
            .union(tracker.reservations.keys)
        let decision = tracker.discoverDecision(
            peer: PCSyncPeerSnapshot(id: peripheral.identifier, state: Self.peerState(peripheral.state)),
            policy: policy,
            isActiveApp: activeApp,
            pendingCount: pendingIds.count,
            now: now
        )
        if !activeApp, peripheral.identifier == policy.remembered,
           decision != .none || tracker.isReserved(peripheral.identifier) {
            stopScan()
        }
        guard decision != .none else { return }
        executeDecision(decision, for: peripheral, central: central, now: now)
        switch decision {
        case .connect(startDelay: nil), .replaceExpiredDelayConnect:
            onEvent?(.status(.connecting))
        case .connect(startDelay: .some), .cancelExpiredDelay, .cancelUnexpectedConnection, .none:
            updateStatus()
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let now = currentNow()
        tracker.finishConnect(peripheral.identifier)
        guard active == nil,
              policy.canAcceptConnection(
                id: peripheral.identifier,
                isCancelling: tracker.isCancelling(peripheral.identifier, now: now),
                now: now
              ) else {
            if peripheral.state != .disconnected {
                peers[peripheral.identifier] = peripheral
                peripheral.delegate = self
                tracker.markCancelling(peripheral.identifier, now: now)
                central.cancelPeripheralConnection(peripheral)
            }
            return
        }
        active = peripheral; peers[peripheral.identifier] = peripheral
        candidateStarted.removeValue(forKey: peripheral.identifier)
        peripheral.delegate = self
        discoveryStarted = now
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
        let now = currentNow()
        // Never log NSError descriptions/userInfo, peripheral names, addresses or UUIDs.
        log("切断; 理由コード=\((error as NSError?)?.code ?? 0)")
        let wasCancelling = tracker.finishDisconnect(peer.identifier)
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
                now: now
            ).nextReconnectAt
        }
        if wasActive {
            clearActive()
            onEvent?(.disconnected(nextReconnectAt: nextReconnectAt))
        }
        seek()
    }
    private static func peerState(_ state: CBPeripheralState) -> PCSyncPeerState {
        switch state {
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .connected: return .connected
        case .disconnecting: return .disconnecting
        @unknown default: return .disconnected
        }
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
