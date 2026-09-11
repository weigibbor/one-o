import Foundation

/// Turns raw lid degrees into a 0...1 fold amount and eases it at display rate.
/// The sensor reports whole degrees, so the raw signal steps; a critically damped spring run once per
/// frame hides the steps without the overshoot a bouncier spring would add.
struct FoldMotion {
    var openAngle: Double          // the lid angle the user calls "open"; the fold starts below it
    var closedAngle: Double = 5    // fully folded at or below this
    private(set) var amount = 0.0
    private var velocity = 0.0

    init(openAngle: Double) { self.openAngle = openAngle }

    func target(for lidAngle: Double?) -> Double {
        guard let lidAngle, openAngle > closedAngle + 3 else { return 0 }
        return min(max((openAngle - lidAngle) / (openAngle - closedAngle), 0), 1)
    }

    /// One frame of critically damped motion, solved exactly so a late frame can never make it overshoot or blow up.
    /// `settle` is roughly the time to arrive.
    mutating func advance(to target: Double, dt: Double, settle: Double = 0.11) {
        guard dt > 0 else { return }
        let omega = 6.0 / max(settle, 0.02)
        let offset = amount - target                     // x(t) = (A + B t) e^{-wt}, x'(t) = (B - w(A + B t)) e^{-wt}
        let b = velocity + omega * offset
        let decay = exp(-omega * dt)
        let next = (offset + b * dt) * decay
        velocity = (b - omega * (offset + b * dt)) * decay
        amount = target + next
        if amount < 0 { amount = 0; velocity = 0 }
        if amount > 1 { amount = 1; velocity = 0 }
    }

    mutating func reset() { amount = 0; velocity = 0 }
    var isIdle: Bool { amount < 0.001 && abs(velocity) < 0.001 }
}

/// Predicts the lid angle between whole-degree sensor steps from the observed step rate, so the fold
/// tracks the lid continuously instead of hopping once per degree.
struct LidTracker {
    private(set) var angle: Double?
    private var lastChange: CFTimeInterval = 0
    private var velocity = 0.0          // degrees per second, signed
    private var stepInterval = 0.0

    mutating func receive(_ value: Double, at now: CFTimeInterval) {
        guard let last = angle else { angle = value; lastChange = now; return }
        guard value != last else { return }
        let dt = max(now - lastChange, 1.0 / 240)
        let v = (value - last) / dt
        velocity = (stepInterval == 0 || (v > 0) != (velocity > 0)) ? v : 0.5 * velocity + 0.5 * v   // reversal: trust the new direction
        stepInterval = dt; lastChange = now; angle = value
    }

    /// True while samples keep arriving and the lid has real angular speed; false once the next sample is overdue.
    func isMoving(at now: CFTimeInterval) -> Bool {
        guard stepInterval > 0 else { return false }
        return abs(velocity) > 1.0 && now - lastChange < max(2.5 * stepInterval, 0.25)
    }

    /// Where the lid most likely is right now: the last sample carried forward at the observed velocity.
    /// This sensor reports about ten times a second in multi-degree jumps, so the carry can span several degrees;
    /// it is capped at two sample intervals and never retracts, so a stopped lid parks instead of wobbling.
    func estimate(at now: CFTimeInterval) -> Double? {
        guard let angle else { return nil }
        guard stepInterval > 0 else { return angle }
        let limit = max(abs(velocity) * stepInterval * 2.0, 0.95)
        let extra = min(max(velocity * (now - lastChange), -limit), limit)
        return angle + extra
    }
}

/// Reference angle for the hold-the-plane effect. Movement of 1.5° or more restarts a debounce; once the lid
/// has been still for `delay`, the reference eases to the current angle over `duration`, which settles the
/// desktop back into place. Behaviour after jh3y/lid-plane (MIT).
struct HoldAnchor {
    private(set) var reference: Double
    var delay: TimeInterval = 0.15
    var duration: TimeInterval = 0.2
    var movementThreshold = 1.5
    private var motionAngle: Double
    private var lastMovement: TimeInterval
    private var settlingSince: TimeInterval?
    private var settlingFrom = 0.0

    init(angle: Double, now: TimeInterval) { reference = angle; motionAngle = angle; lastMovement = now }

    mutating func anchor(at angle: Double, now: TimeInterval) {
        reference = angle; motionAngle = angle; lastMovement = now; settlingSince = nil
    }

    mutating func update(angle: Double, now: TimeInterval, moving: Bool, enabled: Bool) {
        // a lid that is still travelling never counts as at rest, however slowly it moves
        if moving || abs(angle - motionAngle) >= movementThreshold { motionAngle = angle; lastMovement = now; settlingSince = nil }
        guard enabled, now - lastMovement >= delay else { settlingSince = nil; return }
        if abs(reference - angle) < 0.05 { reference = angle; settlingSince = nil; return }
        if settlingSince == nil { settlingSince = now; settlingFrom = reference }
        let progress = min(1, max(0, (now - settlingSince!) / max(0.01, duration)))
        let eased = progress * progress * (3 - 2 * progress)
        reference = settlingFrom + (angle - settlingFrom) * eased
        if progress == 1 { settlingSince = nil }
    }
}
