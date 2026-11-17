import Foundation

enum PCSyncConnectAction: Equatable {
    case wait
    case connect(startDelay: TimeInterval?)
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
            return isActive ? .wait : .connect(startDelay: remaining)
        }
        guard isActive, remaining <= 0 else { return .wait }
        return .connect(startDelay: nil)
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
