import Foundation

enum PCSyncConnectAction: Equatable {
    case wait
    case connect(startDelay: Int?)
}

struct PCSyncReconnectDecision: Equatable {
    let delay: TimeInterval
    let nextReconnectAt: Date?
}

/// Single source of truth for per-peripheral pre-auth backoff and background connection scheduling.
struct PCSyncReconnectPolicy {
    static let reconnectBackoff: [TimeInterval] = [0, 30, 120, 300, 600]
    static let foregroundCooldown: TimeInterval = 3
    static let tenMinuteIgnore: TimeInterval = 600
    private static let maxTrackedPeers = 64

    private(set) var remembered: UUID?
    private var preAuthFailures: [UUID: Int] = [:]
    private var retryAfter: [UUID: Date] = [:]
    private var ignoredUntil: [UUID: Date] = [:]

    mutating func setRemembered(_ id: UUID?) {
        remembered = id
    }

    mutating func reset() {
        remembered = nil
        preAuthFailures.removeAll()
        retryAfter.removeAll()
        ignoredUntil.removeAll()
    }

    mutating func prune(now: Date) {
        ignoredUntil = ignoredUntil.filter { $0.value > now }
        retryAfter = retryAfter.filter { $0.value > now }
        if preAuthFailures.count > Self.maxTrackedPeers {
            preAuthFailures = preAuthFailures.filter { id, _ in
                id == remembered || retryAfter[id] != nil || ignoredUntil[id] != nil
            }
        }
    }

    mutating func recordAuthenticated(id: UUID) {
        remembered = id
        preAuthFailures.removeValue(forKey: id)
        retryAfter.removeValue(forKey: id)
        ignoredUntil.removeValue(forKey: id)
    }

    mutating func recordCandidateTimeout(id: UUID, now: Date) {
        guard id != remembered else { return }
        retryAfter[id] = now.addingTimeInterval(Self.foregroundCooldown)
    }

    @discardableResult
    mutating func recordDisconnect(
        id: UUID,
        reason: PCSyncDisconnectReason,
        isActive: Bool,
        now: Date
    ) -> PCSyncReconnectDecision {
        switch reason {
        case .rejectTenMinutes:
            ignoredUntil[id] = now.addingTimeInterval(Self.tenMinuteIgnore)
            retryAfter.removeValue(forKey: id)
            return PCSyncReconnectDecision(delay: 0, nextReconnectAt: nil)
        case .preAuthFailure:
            let count = (preAuthFailures[id] ?? 0) + 1
            preAuthFailures[id] = count
            let delay = Self.backoffDelay(forFailures: count)
            applyRetryDelay(delay, for: id, isActive: isActive, now: now)
            return PCSyncReconnectDecision(
                delay: delay,
                nextReconnectAt: delay > 0 ? now.addingTimeInterval(delay) : nil
            )
        case .immediate:
            applyRetryDelay(0, for: id, isActive: isActive, now: now)
            return PCSyncReconnectDecision(delay: 0, nextReconnectAt: nil)
        }
    }

    func connectAction(for id: UUID, isCancelling: Bool, isActive: Bool, now: Date) -> PCSyncConnectAction {
        guard !isCancelling else { return .wait }
        let remaining = remainingWait(for: id, now: now)
        if id == remembered {
            if remaining <= 0 {
                return .connect(startDelay: nil)
            }
            return isActive ? .wait : .connect(startDelay: Self.startDelaySeconds(for: remaining))
        }
        guard isActive, remaining <= 0 else { return .wait }
        return .connect(startDelay: nil)
    }

    static func startDelaySeconds(for remaining: TimeInterval) -> Int {
        max(1, Int(ceil(remaining)))
    }

    func canAcceptConnection(id: UUID, isCancelling: Bool, now: Date) -> Bool {
        guard !isCancelling else { return false }
        if id == remembered {
            // Background start-delay timers run inside CoreBluetooth; small wakeup jitter must not reject them.
            return true
        }
        return remainingWait(for: id, now: now) <= 0
    }

    func failureCount(for id: UUID) -> Int {
        preAuthFailures[id] ?? 0
    }

    private func remainingWait(for id: UUID, now: Date) -> TimeInterval {
        let retry = retryAfter[id]?.timeIntervalSince(now) ?? 0
        let ignored = ignoredUntil[id]?.timeIntervalSince(now) ?? 0
        return max(0, max(retry, ignored))
    }

    private mutating func applyRetryDelay(_ delay: TimeInterval, for id: UUID, isActive: Bool, now: Date) {
        if delay > 0 {
            retryAfter[id] = now.addingTimeInterval(delay)
        } else if id == remembered && !isActive {
            retryAfter.removeValue(forKey: id)
        } else {
            retryAfter[id] = now.addingTimeInterval(Self.foregroundCooldown)
        }
    }

    private static func backoffDelay(forFailures count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        return reconnectBackoff[min(count - 1, reconnectBackoff.count - 1)]
    }
}

enum PCSyncPeerState: Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

struct PCSyncPeerSnapshot: Equatable {
    let id: UUID
    let state: PCSyncPeerState
}

enum PCSyncRestoreAction: Equatable {
    case cancel(UUID)
    case trackCancelling(UUID)
    case keepReserved(UUID)
    case remove(UUID)
}

enum PCSyncReservationDecision: Equatable {
    case none
    case connect(startDelay: Int?)
    case replaceExpiredDelayConnect
    case cancelExpiredDelay(UUID)
    case cancelUnexpectedConnection(UUID)
}

struct PCSyncSeekPlan: Equatable {
    let decision: PCSyncReservationDecision
    let needsBackgroundScan: Bool
}

/// Tracks CoreBluetooth connection reservations and cancelling timeouts independently of CB objects.
struct PCSyncConnectionTracker {
    static let cancellingTimeout: TimeInterval = 10

    struct Reservation: Equatable {
        var hasStartDelay: Bool
    }

    private(set) var cancelling: [UUID: Date] = [:]
    private(set) var reservations: [UUID: Reservation] = [:]

    mutating func resetAll() {
        cancelling.removeAll()
        reservations.removeAll()
    }

    mutating func pruneCancelling(now: Date) {
        cancelling = cancelling.filter { now.timeIntervalSince($0.value) < Self.cancellingTimeout }
    }

    func isCancelling(_ id: UUID, now: Date) -> Bool {
        guard let started = cancelling[id] else { return false }
        return now.timeIntervalSince(started) < Self.cancellingTimeout
    }

    mutating func markCancelling(_ id: UUID, now: Date) {
        reservations.removeValue(forKey: id)
        cancelling[id] = now
    }

    @discardableResult
    mutating func finishDisconnect(_ id: UUID) -> Bool {
        reservations.removeValue(forKey: id)
        return cancelling.removeValue(forKey: id) != nil
    }

    mutating func finishConnect(_ id: UUID) {
        reservations.removeValue(forKey: id)
    }

    func isReserved(_ id: UUID) -> Bool {
        reservations[id] != nil
    }

    /// Evaluates restored/held peripherals once CentralManager transitions to `.poweredOn`.
    /// Recreates `cancelling` so stale cancellation entries from before `.poweredOn` never linger.
    mutating func handlePoweredOn(
        restoredPeers: [PCSyncPeerSnapshot],
        remembered: UUID?,
        activeId: UUID?,
        now: Date
    ) -> [PCSyncRestoreAction] {
        cancelling.removeAll()
        reservations.removeAll()
        var actions: [PCSyncRestoreAction] = []
        for peer in restoredPeers where peer.id != activeId {
            if peer.id == remembered {
                switch peer.state {
                case .connected:
                    cancelling[peer.id] = now
                    actions.append(.cancel(peer.id))
                case .disconnecting:
                    cancelling[peer.id] = now
                    actions.append(.trackCancelling(peer.id))
                case .connecting:
                    reservations[peer.id] = Reservation(hasStartDelay: false)
                    actions.append(.keepReserved(peer.id))
                case .disconnected:
                    break
                }
            } else {
                switch peer.state {
                case .connected, .connecting:
                    cancelling[peer.id] = now
                    actions.append(.cancel(peer.id))
                case .disconnecting:
                    cancelling[peer.id] = now
                    actions.append(.trackCancelling(peer.id))
                case .disconnected:
                    actions.append(.remove(peer.id))
                }
            }
        }
        return actions
    }

    mutating func rememberedSeekPlan(
        peer: PCSyncPeerSnapshot?,
        policy: PCSyncReconnectPolicy,
        isActiveApp: Bool,
        now: Date
    ) -> PCSyncSeekPlan {
        pruneCancelling(now: now)
        guard let remembered = policy.remembered else {
            return PCSyncSeekPlan(decision: .none, needsBackgroundScan: false)
        }
        guard let peer else {
            let shouldScan = !isActiveApp && !isCancelling(remembered, now: now)
            return PCSyncSeekPlan(decision: .none, needsBackgroundScan: shouldScan)
        }
        if peer.state == .connected, !isCancelling(peer.id, now: now) {
            markCancelling(peer.id, now: now)
            return PCSyncSeekPlan(decision: .cancelUnexpectedConnection(peer.id), needsBackgroundScan: false)
        }
        let action = policy.connectAction(
            for: peer.id,
            isCancelling: isCancelling(peer.id, now: now),
            isActive: isActiveApp,
            now: now
        )
        return PCSyncSeekPlan(
            decision: applyAction(action, to: peer, enforceCandidateLimit: false, pendingCount: reservations.count, now: now),
            needsBackgroundScan: false
        )
    }

    mutating func discoverDecision(
        peer: PCSyncPeerSnapshot,
        policy: PCSyncReconnectPolicy,
        isActiveApp: Bool,
        pendingCount: Int,
        now: Date
    ) -> PCSyncReservationDecision {
        pruneCancelling(now: now)
        guard peer.state != .connected else { return .none }
        let action = policy.connectAction(
            for: peer.id,
            isCancelling: isCancelling(peer.id, now: now),
            isActive: isActiveApp,
            now: now
        )
        return applyAction(
            action,
            to: peer,
            enforceCandidateLimit: peer.id != policy.remembered,
            pendingCount: pendingCount,
            now: now
        )
    }

    private mutating func applyAction(
        _ action: PCSyncConnectAction,
        to peer: PCSyncPeerSnapshot,
        enforceCandidateLimit: Bool,
        pendingCount: Int,
        now: Date
    ) -> PCSyncReservationDecision {
        switch action {
        case .wait:
            return .none
        case .connect(let startDelay):
            if let existing = reservations[peer.id] {
                if existing.hasStartDelay && startDelay == nil {
                    reservations.removeValue(forKey: peer.id)
                    if peer.state == .disconnected {
                        reservations[peer.id] = Reservation(hasStartDelay: false)
                        return .replaceExpiredDelayConnect
                    }
                    cancelling[peer.id] = now
                    return .cancelExpiredDelay(peer.id)
                }
                return .none
            }
            if enforceCandidateLimit, pendingCount >= 2 {
                return .none
            }
            switch peer.state {
            case .disconnected:
                reservations[peer.id] = Reservation(hasStartDelay: startDelay != nil)
                return .connect(startDelay: startDelay)
            case .connecting:
                reservations[peer.id] = Reservation(hasStartDelay: startDelay != nil)
                return .none
            case .connected, .disconnecting:
                return .none
            }
        }
    }
}
