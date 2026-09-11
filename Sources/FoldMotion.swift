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

    /// One frame of critically damped motion; `settle` is roughly the time to arrive.
    mutating func advance(to target: Double, dt: Double, settle: Double = 0.13) {
        let step = min(max(dt, 0), 1.0 / 30)     // a dropped frame must not launch the spring
        guard step > 0 else { return }
        let omega = 6.0 / settle
        velocity += (omega * omega * (target - amount) - 2 * omega * velocity) * step
        amount += velocity * step
        if amount < 0 { amount = 0; velocity = 0 }
        if amount > 1 { amount = 1; velocity = 0 }
    }

    mutating func reset() { amount = 0; velocity = 0 }
    var isIdle: Bool { amount < 0.001 && abs(velocity) < 0.001 }
}
