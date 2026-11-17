import Foundation
import XCTest
@testable import ClipboardPlus

final class PCSyncReconnectPolicyTests: XCTestCase {
    func testBackgroundAlwaysArmsRememberedWithStartDelayDuringWaitAndForegroundTransitions() {
        var policy = PCSyncReconnectPolicy()
        let remembered = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var now = base
        var isActive = true

        policy.setRemembered(remembered)
        XCTAssertEqual(policy.connectAction(for: remembered, isCancelling: false, isActive: isActive, now: now),
                       .connect(startDelay: nil))

        // 1st pre-auth failure in foreground gets 3s cooldown; entering background arms remaining delay.
        let first = policy.recordDisconnect(id: remembered, reason: .preAuthFailure, isActive: isActive, now: now)
        XCTAssertEqual(first, PCSyncReconnectDecision(delay: 0, nextReconnectAt: nil))
        XCTAssertEqual(policy.connectAction(for: remembered, isCancelling: false, isActive: isActive, now: now), .wait)

        now.addTimeInterval(1)
        isActive = false
        XCTAssertEqual(policy.connectAction(for: remembered, isCancelling: false, isActive: isActive, now: now),
                       .connect(startDelay: 2))

        // 2nd pre-auth failure while in background schedules 30s start delay immediately once not cancelling.
        let second = policy.recordDisconnect(id: remembered, reason: .preAuthFailure, isActive: isActive, now: now)
        XCTAssertEqual(second, PCSyncReconnectDecision(delay: 30, nextReconnectAt: now.addingTimeInterval(30)))
        XCTAssertEqual(policy.connectAction(for: remembered, isCancelling: true, isActive: isActive, now: now), .wait)
        XCTAssertEqual(policy.connectAction(for: remembered, isCancelling: false, isActive: isActive, now: now),
                       .connect(startDelay: 30))

        // 3rd pre-auth failure in foreground waits, then moving to background after 25s arms remaining 95s delay.
        isActive = true
        let third = policy.recordDisconnect(id: remembered, reason: .preAuthFailure, isActive: isActive, now: now)
        XCTAssertEqual(third, PCSyncReconnectDecision(delay: 120, nextReconnectAt: now.addingTimeInterval(120)))
        now.addTimeInterval(25)
        XCTAssertEqual(policy.connectAction(for: remembered, isCancelling: false, isActive: isActive, now: now), .wait)
        isActive = false
        XCTAssertEqual(policy.connectAction(for: remembered, isCancelling: false, isActive: isActive, now: now),
                       .connect(startDelay: 95))

        // Once wait expires (even after prune), failure count stays intact until authenticated.
        now.addTimeInterval(95)
        policy.prune(now: now)
        XCTAssertEqual(policy.failureCount(for: remembered), 3)
        XCTAssertEqual(policy.connectAction(for: remembered, isCancelling: false, isActive: true, now: now),
                       .connect(startDelay: nil))
        XCTAssertEqual(policy.connectAction(for: remembered, isCancelling: false, isActive: false, now: now),
                       .connect(startDelay: nil))

        // Post-auth immediate disconnect in background re-arms immediately with nil start delay.
        policy.recordAuthenticated(id: remembered)
        XCTAssertEqual(policy.failureCount(for: remembered), 0)
        let postAuth = policy.recordDisconnect(id: remembered, reason: .immediate, isActive: false, now: now)
        XCTAssertEqual(postAuth, PCSyncReconnectDecision(delay: 0, nextReconnectAt: nil))
        XCTAssertEqual(policy.connectAction(for: remembered, isCancelling: false, isActive: false, now: now),
                       .connect(startDelay: nil))
    }

    func testBackoffIsPerPeripheralAndIgnoresTenMinuteRejectAndCandidateTimeout() {
        var policy = PCSyncReconnectPolicy()
        let remembered = UUID()
        let candidate = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var now = base

        policy.setRemembered(remembered)

        // Candidate failing repeatedly and timing out never affects remembered or connects in background.
        let candidateDelays = (0..<6).map { _ in
            policy.recordDisconnect(id: candidate, reason: .preAuthFailure, isActive: true, now: now).delay
        }
        XCTAssertEqual(candidateDelays, [0, 30, 120, 300, 600, 600])
        policy.recordCandidateTimeout(id: candidate, now: now)
        XCTAssertEqual(policy.connectAction(for: candidate, isCancelling: false, isActive: false, now: now.addingTimeInterval(700)),
                       .wait)
        XCTAssertEqual(policy.failureCount(for: remembered), 0)

        // 10-minute reject sets wait window without advancing pre-auth failure count.
        let rejected = policy.recordDisconnect(id: remembered, reason: .rejectTenMinutes, isActive: false, now: now)
        XCTAssertEqual(rejected, PCSyncReconnectDecision(delay: 0, nextReconnectAt: nil))
        XCTAssertEqual(policy.failureCount(for: remembered), 0)
        XCTAssertEqual(policy.connectAction(for: remembered, isCancelling: false, isActive: false, now: now),
                       .connect(startDelay: 600))
        XCTAssertEqual(policy.connectAction(for: remembered, isCancelling: false, isActive: true, now: now), .wait)

        now.addTimeInterval(600)
        let afterReject = policy.recordDisconnect(id: remembered, reason: .preAuthFailure, isActive: true, now: now)
        XCTAssertEqual(afterReject.delay, 0)
        XCTAssertEqual(policy.failureCount(for: remembered), 1)
    }

    func testCanAcceptConnectionAllowsRememberedJitterAndBlocksNonRememberedDuringCooldown() {
        var policy = PCSyncReconnectPolicy()
        let remembered = UUID()
        let candidate = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        policy.setRemembered(remembered)
        _ = policy.recordDisconnect(id: remembered, reason: .preAuthFailure, isActive: false, now: now)
        _ = policy.recordDisconnect(id: remembered, reason: .preAuthFailure, isActive: false, now: now)
        // Even before retryAfter expires on wall clock, CoreBluetooth completion for remembered is accepted if not cancelling.
        XCTAssertTrue(policy.canAcceptConnection(id: remembered, isCancelling: false, now: now.addingTimeInterval(29.9)))
        XCTAssertFalse(policy.canAcceptConnection(id: remembered, isCancelling: true, now: now.addingTimeInterval(35)))

        _ = policy.recordDisconnect(id: candidate, reason: .immediate, isActive: true, now: now)
        XCTAssertFalse(policy.canAcceptConnection(id: candidate, isCancelling: false, now: now.addingTimeInterval(2)))
        XCTAssertTrue(policy.canAcceptConnection(id: candidate, isCancelling: false, now: now.addingTimeInterval(3)))
    }

    func testStartDelayRoundsUpToAtLeastOneWholeSecond() {
        var policy = PCSyncReconnectPolicy()
        let remembered = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        policy.setRemembered(remembered)
        _ = policy.recordDisconnect(id: remembered, reason: .preAuthFailure, isActive: true, now: base)

        let fractional = policy.connectAction(for: remembered, isCancelling: false, isActive: false, now: base.addingTimeInterval(2.8))
        guard case .connect(let subSecondDelay?) = fractional else {
            return XCTFail("Expected connect action with whole-second delay")
        }
        let wholeSubSecond: Int = subSecondDelay
        XCTAssertEqual(wholeSubSecond, 1)

        _ = policy.recordDisconnect(id: remembered, reason: .preAuthFailure, isActive: false, now: base)
        let backoff = policy.connectAction(for: remembered, isCancelling: false, isActive: false, now: base.addingTimeInterval(0.9))
        XCTAssertEqual(backoff, .connect(startDelay: 30))
        XCTAssertEqual(PCSyncReconnectPolicy.startDelaySeconds(for: 0.01), 1)
    }

    func testPoweredOnRestoreHandlingAndCancellingTimeoutReset() {
        let remembered = UUID()
        let staleConnected = UUID()
        let staleConnecting = UUID()
        let staleDisconnected = UUID()
        let staleDisconnecting = UUID()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var tracker = PCSyncConnectionTracker()

        // Stale cancelling entry from before power cycle must be cleared on .poweredOn.
        tracker.markCancelling(remembered, now: now)
        XCTAssertTrue(tracker.isCancelling(remembered, now: now))

        let actions1 = tracker.handlePoweredOn(
            restoredPeers: [
                PCSyncPeerSnapshot(id: remembered, state: .connected),
                PCSyncPeerSnapshot(id: staleConnected, state: .connected),
                PCSyncPeerSnapshot(id: staleConnecting, state: .connecting),
                PCSyncPeerSnapshot(id: staleDisconnected, state: .disconnected),
                PCSyncPeerSnapshot(id: staleDisconnecting, state: .disconnecting)
            ],
            remembered: remembered,
            activeId: nil,
            now: now
        )
        XCTAssertEqual(actions1, [
            .cancel(remembered),
            .cancel(staleConnected),
            .cancel(staleConnecting),
            .remove(staleDisconnected),
            .trackCancelling(staleDisconnecting)
        ])
        XCTAssertTrue(tracker.isCancelling(remembered, now: now))
        XCTAssertFalse(tracker.isCancelling(staleDisconnected, now: now))

        // If didDisconnectPeripheral never arrives, cancelling expires after timeout so remembered can reconnect.
        var policy = PCSyncReconnectPolicy()
        policy.setRemembered(remembered)
        let whileCancelling = tracker.rememberedSeekPlan(
            peer: PCSyncPeerSnapshot(id: remembered, state: .disconnected),
            policy: policy,
            isActiveApp: false,
            now: now.addingTimeInterval(5)
        )
        XCTAssertEqual(whileCancelling, PCSyncSeekPlan(decision: .none, needsBackgroundScan: false))

        now = now.addingTimeInterval(PCSyncConnectionTracker.cancellingTimeout)
        let afterTimeout = tracker.rememberedSeekPlan(
            peer: PCSyncPeerSnapshot(id: remembered, state: .disconnected),
            policy: policy,
            isActiveApp: false,
            now: now
        )
        XCTAssertEqual(afterTimeout, PCSyncSeekPlan(decision: .connect(startDelay: nil), needsBackgroundScan: false))
        XCTAssertFalse(tracker.isCancelling(remembered, now: now))

        // Restored .connecting remembered peer stays reserved across .poweredOn without duplicate connect.
        let actions2 = tracker.handlePoweredOn(
            restoredPeers: [PCSyncPeerSnapshot(id: remembered, state: .connecting)],
            remembered: remembered,
            activeId: nil,
            now: now
        )
        XCTAssertEqual(actions2, [.keepReserved(remembered)])
        XCTAssertTrue(tracker.isReserved(remembered))
        let duplicateSeek = tracker.rememberedSeekPlan(
            peer: PCSyncPeerSnapshot(id: remembered, state: .connecting),
            policy: policy,
            isActiveApp: false,
            now: now
        )
        XCTAssertEqual(duplicateSeek, PCSyncSeekPlan(decision: .none, needsBackgroundScan: false))
    }

    func testReservationPreventsDuplicateConnectAndReplacesExpiredDelayedReservation() {
        var policy = PCSyncReconnectPolicy()
        var tracker = PCSyncConnectionTracker()
        let remembered = UUID()
        let candidate1 = UUID()
        let candidate2 = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        policy.setRemembered(remembered)
        _ = policy.recordDisconnect(id: remembered, reason: .preAuthFailure, isActive: false, now: base)
        _ = policy.recordDisconnect(id: remembered, reason: .preAuthFailure, isActive: false, now: base) // 30s delay

        // First background seek schedules delayed connect.
        let first = tracker.rememberedSeekPlan(
            peer: PCSyncPeerSnapshot(id: remembered, state: .disconnected),
            policy: policy,
            isActiveApp: false,
            now: base
        )
        XCTAssertEqual(first, PCSyncSeekPlan(decision: .connect(startDelay: 30), needsBackgroundScan: false))

        // Subsequent ticks while waiting do NOT re-call connect, even if CB state stays .disconnected.
        let retryWhileDisconnected = tracker.rememberedSeekPlan(
            peer: PCSyncPeerSnapshot(id: remembered, state: .disconnected),
            policy: policy,
            isActiveApp: false,
            now: base.addingTimeInterval(3)
        )
        XCTAssertEqual(retryWhileDisconnected, PCSyncSeekPlan(decision: .none, needsBackgroundScan: false))

        // Returning to foreground before wait expires keeps the delayed reservation untouched.
        let earlyForeground = tracker.rememberedSeekPlan(
            peer: PCSyncPeerSnapshot(id: remembered, state: .connecting),
            policy: policy,
            isActiveApp: true,
            now: base.addingTimeInterval(15)
        )
        XCTAssertEqual(earlyForeground, PCSyncSeekPlan(decision: .none, needsBackgroundScan: false))

        // After 30s wait expires (e.g. after device sleep), a still-.connecting delayed reservation is cancelled and re-armed without delay.
        let expiredConnecting = tracker.rememberedSeekPlan(
            peer: PCSyncPeerSnapshot(id: remembered, state: .connecting),
            policy: policy,
            isActiveApp: true,
            now: base.addingTimeInterval(31)
        )
        XCTAssertEqual(expiredConnecting, PCSyncSeekPlan(decision: .cancelExpiredDelay(remembered), needsBackgroundScan: false))
        XCTAssertTrue(tracker.finishDisconnect(remembered))
        let rearmed = tracker.rememberedSeekPlan(
            peer: PCSyncPeerSnapshot(id: remembered, state: .disconnected),
            policy: policy,
            isActiveApp: true,
            now: base.addingTimeInterval(31)
        )
        XCTAssertEqual(rearmed, PCSyncSeekPlan(decision: .connect(startDelay: nil), needsBackgroundScan: false))

        // If a delayed reservation stayed .disconnected until expiry, it replaces immediately without waiting for disconnect callback.
        _ = policy.recordDisconnect(id: remembered, reason: .preAuthFailure, isActive: false, now: base.addingTimeInterval(31)) // 120s
        var tracker2 = PCSyncConnectionTracker()
        XCTAssertEqual(
            tracker2.rememberedSeekPlan(
                peer: PCSyncPeerSnapshot(id: remembered, state: .disconnected),
                policy: policy,
                isActiveApp: false,
                now: base.addingTimeInterval(31)
            ).decision,
            .connect(startDelay: 120)
        )
        XCTAssertEqual(
            tracker2.rememberedSeekPlan(
                peer: PCSyncPeerSnapshot(id: remembered, state: .disconnected),
                policy: policy,
                isActiveApp: true,
                now: base.addingTimeInterval(151)
            ).decision,
            .replaceExpiredDelayConnect
        )
        XCTAssertEqual(
            tracker2.rememberedSeekPlan(
                peer: PCSyncPeerSnapshot(id: remembered, state: .disconnected),
                policy: policy,
                isActiveApp: true,
                now: base.addingTimeInterval(152)
            ).decision,
            .none
        )

        // Foreground discovery avoids duplicate connect for reserved candidate and enforces 2-slot candidate limit while allowing remembered.
        var discoverTracker = PCSyncConnectionTracker()
        XCTAssertEqual(
            discoverTracker.discoverDecision(
                peer: PCSyncPeerSnapshot(id: candidate1, state: .disconnected),
                policy: policy,
                isActiveApp: true,
                pendingCount: 0,
                now: base.addingTimeInterval(160)
            ),
            .connect(startDelay: nil)
        )
        XCTAssertEqual(
            discoverTracker.discoverDecision(
                peer: PCSyncPeerSnapshot(id: candidate1, state: .disconnected),
                policy: policy,
                isActiveApp: true,
                pendingCount: 1,
                now: base.addingTimeInterval(160)
            ),
            .none
        )
        XCTAssertEqual(
            discoverTracker.discoverDecision(
                peer: PCSyncPeerSnapshot(id: candidate2, state: .disconnected),
                policy: policy,
                isActiveApp: true,
                pendingCount: 2,
                now: base.addingTimeInterval(160)
            ),
            .none
        )
        XCTAssertEqual(
            discoverTracker.discoverDecision(
                peer: PCSyncPeerSnapshot(id: remembered, state: .disconnected),
                policy: policy,
                isActiveApp: true,
                pendingCount: 2,
                now: base.addingTimeInterval(160)
            ),
            .connect(startDelay: nil)
        )
    }

    func testBackgroundScanWhenRetrieveReturnsEmptyAndConnectsRememberedWithStartDelayOnDiscovery() {
        var policy = PCSyncReconnectPolicy()
        var tracker = PCSyncConnectionTracker()
        let remembered = UUID()
        let unknown = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        policy.setRemembered(remembered)
        _ = policy.recordDisconnect(id: remembered, reason: .preAuthFailure, isActive: false, now: now)
        _ = policy.recordDisconnect(id: remembered, reason: .preAuthFailure, isActive: false, now: now) // 30s delay

        // Background + retrievePeripherals empty -> requests background scan.
        XCTAssertEqual(
            tracker.rememberedSeekPlan(peer: nil, policy: policy, isActiveApp: false, now: now),
            PCSyncSeekPlan(decision: .none, needsBackgroundScan: true)
        )
        // Foreground + retrievePeripherals empty -> does not request background-only scan.
        XCTAssertEqual(
            tracker.rememberedSeekPlan(peer: nil, policy: policy, isActiveApp: true, now: now),
            PCSyncSeekPlan(decision: .none, needsBackgroundScan: false)
        )

        // Discovering an unrelated peripheral in background is ignored.
        XCTAssertEqual(
            tracker.discoverDecision(
                peer: PCSyncPeerSnapshot(id: unknown, state: .disconnected),
                policy: policy,
                isActiveApp: false,
                pendingCount: 0,
                now: now
            ),
            .none
        )

        // Discovering remembered in background arms connection with remaining startDelay.
        XCTAssertEqual(
            tracker.discoverDecision(
                peer: PCSyncPeerSnapshot(id: remembered, state: .disconnected),
                policy: policy,
                isActiveApp: false,
                pendingCount: 0,
                now: now.addingTimeInterval(5)
            ),
            .connect(startDelay: 25)
        )

        // Once discovered and kept in peers, background seek no longer scans or re-calls connect.
        XCTAssertEqual(
            tracker.rememberedSeekPlan(
                peer: PCSyncPeerSnapshot(id: remembered, state: .connecting),
                policy: policy,
                isActiveApp: false,
                now: now.addingTimeInterval(6)
            ),
            PCSyncSeekPlan(decision: .none, needsBackgroundScan: false)
        )
    }
}
