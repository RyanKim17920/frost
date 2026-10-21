import Foundation

/// What a click on the Frost icon does in Frost Bar mode.
///
/// Opening can take a moment before the panel is on screen: a previous click forward's item may still be lingering in
/// the Visible section, and the panel waits for it to move back (end the linger, ⌘-drag, settle; measured 0.6–0.9 s).
/// A user who sees nothing happen clicks again; that click must not close (and cancel) an open that isn't visible yet,
/// or the Frost icon seems to ignore clicks. The same goes for a click that lands just after the panel appeared
/// (`reactionGrace`): it was made before the user could see the panel.
///
/// That wait is normally short, but it is a wait on the previous click forward, which waits for its menu / popover to
/// close (menus without a time limit, popovers up to a minute). An open still waiting after `stalledOpening` is stuck
/// behind that; keeping it "opening" would swallow every further click on the icon, so the next click ends the wait
/// (`endStalledWait`).
public enum FrostBarIconClick {
    public enum Phase: Equatable, Sendable {
        /// The panel is closed.
        case closed
        /// Opening was requested at the given instant but the panel isn't on screen yet.
        case opening(since: ContinuousClock.Instant)
        /// The panel is on screen since the given instant.
        case presented(at: ContinuousClock.Instant)
    }

    public enum Action: Equatable, Sendable {
        case open(showAlwaysHidden: Bool)
        case close
        /// Ignore the click as a toggle: the panel is (about to be) shown. A non-nil value is a ⌥-click asking to show
        /// the Always Hidden section.
        case keepOpening(showAlwaysHidden: Bool?)
        /// The open has waited `stalledOpening` already: end what it waits for (the previous click forward) so the
        /// panel can appear. `showAlwaysHidden` as in `keepOpening`.
        case endStalledWait(showAlwaysHidden: Bool?)
        /// ⌥-click on the shown panel: show / hide the Always Hidden section.
        case setAlwaysHidden(Bool)
    }

    /// Clicks closer than this to the panel's appearance count as made before the user saw it (human reaction time).
    public static let reactionGrace: Duration = .milliseconds(300)
    /// How long an open may wait before a click on the icon ends the wait (normally under a second, see above).
    public static let stalledOpening: Duration = .seconds(2)

    public static func decide(phase: Phase, option: Bool, showingAlwaysHidden: Bool,
                              now: ContinuousClock.Instant) -> Action {
        switch phase {
        case .closed:
            return .open(showAlwaysHidden: option)
        case .opening(let since):
            if now - since >= stalledOpening { return .endStalledWait(showAlwaysHidden: option ? true : nil) }
            return .keepOpening(showAlwaysHidden: option ? true : nil)
        case .presented(let shownAt):
            if now - shownAt < reactionGrace { return .keepOpening(showAlwaysHidden: option ? true : nil) }
            return option ? .setAlwaysHidden(!showingAlwaysHidden) : .close
        }
    }

    /// How long after the panel appears a loss of key focus or a change of the active Space is taken as left over from
    /// what happened before the click (the system settling focus after the user switched desktops), not as the user
    /// leaving the panel.
    public static let focusChangeGrace: Duration = .seconds(1)

    /// Whether the panel closes when it stops being the key window (`shownAt`: when it appeared, nil while opening).
    /// Losing key focus means the user went elsewhere, but not within `focusChangeGrace` of the panel appearing: right
    /// after a switch to another desktop the system can still move focus to that desktop's frontmost window, and closing
    /// then makes the click that opened the panel look ignored. Clicks elsewhere still close it through the
    /// outside-click monitors.
    public static func closesOnResignKey(shownAt: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Bool {
        guard let shownAt else { return false }
        return now - shownAt >= focusChangeGrace
    }

    /// Whether the panel closes when the active Space (desktop) changes. The panel is on every Space, so it only closes
    /// for a switch the user made while it was in use: an open still in progress goes on (cancelling it swallowed the
    /// click), and a change reported within `focusChangeGrace` of the panel appearing is the late notice of the switch
    /// the user made before clicking.
    public static func closesOnSpaceChange(shownAt: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Bool {
        guard let shownAt else { return false }
        return now - shownAt >= focusChangeGrace
    }
}

/// What a plain click on the Frost icon does while the layout editor holds the menu bar in its editing state (every
/// icon drawn, the section boundaries shown as lines).
///
/// The editor holds it for as long as the Settings window is open on the Layout tab and visible, even partly, behind
/// other apps' windows. A click on the icon used to be ignored silently then, so the icon seemed broken until the user
/// came back to Settings and closed it.
public enum IconClickWhileEditing {
    public enum Action: Equatable, Sendable {
        /// The user is working in the editor (its window is key): the menu bar stays as it is.
        case ignore
        /// The editor yields the menu bar until its window is used again, then the click is handled as usual.
        case yieldEditor
    }

    /// How long the click waits for the menu bar to leave editing (the editor first waits for a move in progress).
    public static let yieldTimeout: Duration = .seconds(3)

    public static func decide(editorWindowIsKey: Bool) -> Action {
        editorWindowIsKey ? .ignore : .yieldEditor
    }
}

/// Where the Frost icon ends up once a lingering item right of it moves back to its hidden slot.
///
/// A forwarded item lingers directly right of the Frost icon (`.rightOf(icon)`); status items are right-aligned, so when
/// it leaves, the icon and everything left of it slide right by the item's width plus one gap: the icon's right edge
/// lands where the item's right edge was. The Frost Bar opened during the linger is placed under that final position
/// as soon as the item has been dropped, instead of after the ~0.4 s slide (the user would otherwise see nothing for
/// over half a second and click again — at the icon's old place, now another item).
public enum LingerReturnAnchor {
    /// The icon's right edge after `item` leaves, or nil when `item` isn't the icon's right-hand neighbor (any x
    /// coordinate system; only differences matter).
    public static func iconMaxX(icon: CGRect, item: CGRect, maxGap: CGFloat = 16) -> CGFloat? {
        let gap = item.minX - icon.maxX
        guard gap >= -1, gap <= maxGap, item.width > 0 else { return nil }
        return item.maxX
    }
}
