/// Whether the user is at the Mac: the displays are awake, the screen isn't locked, the login session is the active
/// (console) one and the system isn't going to sleep. While away, nothing Frost shows can be seen, so periodic work
/// that touches the menu bar (Frost Bar live refresh, layout editor refreshes) pauses.
public struct UserPresence: Equatable, Sendable {
    public enum Reason: String, CaseIterable, Sendable {
        case displaysAsleep, screenLocked, sessionInactive, systemSleeping
    }

    /// Why the user is away (empty = present).
    public private(set) var reasons: Set<Reason> = []

    public init(reasons: Set<Reason> = []) {
        self.reasons = reasons
    }

    public var isAway: Bool { !reasons.isEmpty }

    /// Records that `reason` started (`true`) or ended (`false`); returns whether `isAway` changed. Each reason ends
    /// only with its own counterpart (waking the displays doesn't unlock the screen).
    @discardableResult
    public mutating func update(_ reason: Reason, _ active: Bool) -> Bool {
        let wasAway = isAway
        if active { reasons.insert(reason) } else { reasons.remove(reason) }
        return wasAway != isAway
    }

    /// The user just clicked one of Frost's own controls, so they are at the Mac whatever the notifications said: a
    /// reason whose end was never reported (a missed wake or unlock) would otherwise keep the Frost Bar from opening
    /// until the next sleep. Returns whether `isAway` changed.
    @discardableResult
    public mutating func confirmPresent() -> Bool {
        let wasAway = isAway
        reasons.removeAll()
        return wasAway
    }
}
