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
}
