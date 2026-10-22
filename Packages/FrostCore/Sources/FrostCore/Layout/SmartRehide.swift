import CoreGraphics
import Foundation

/// Decides when hidden icons revealed in the menu bar go away again because the user is done with them ("Rehide when
/// you're done"), ahead of the delay timer, which stays as the fallback.
///
/// - A **presentation** (a menu, or a popover-like window hanging from the menu bar, `MenuBarPresentation`) was open
///   and has closed: collapse once the pointer has been out of the menu bar for `closeGrace`. That is the user picking
///   an entry, pressing Esc or clicking a popover closed.
/// - The **frontmost app changed** since the icons were revealed (⌘-Tab, a click on a revealed icon that activated
///   its app and opened a window): collapse once the pointer has been out of the menu bar for `switchGrace`.
/// - Both graces leave the user a moment (about 2 s) to look at the revealed icons or open another one before they go,
///   rather than hiding them the instant the menu closes.
/// - Never while the pointer is in the menu bar, a presentation is open or a mouse button is held.
///
/// A pure state machine: the caller polls with samples, and owns the window baseline (`acceptsNewBaseline`).
public struct SmartRehide: Sendable {
    public struct Timing: Equatable, Sendable {
        /// How long the pointer must be out of the menu bar after a presentation closed.
        public var closeGrace: Duration
        /// How long the pointer must be out of the menu bar after the frontmost app changed.
        public var switchGrace: Duration
        /// How long nothing must have happened in the menu bar before new windows count as unrelated.
        public var baselineQuiet: Duration

        public init(closeGrace: Duration, switchGrace: Duration, baselineQuiet: Duration) {
            self.closeGrace = closeGrace
            self.switchGrace = switchGrace
            self.baselineQuiet = baselineQuiet
        }

        /// `baselineQuiet` stays longer than both graces: a popover that appears a little after its app activates
        /// must not be absorbed into the baseline before the collapse is decided.
        public static let standard = Timing(closeGrace: .seconds(2), switchGrace: .seconds(2),
                                            baselineQuiet: .milliseconds(2500))
    }

    public struct Sample: Equatable, Sendable {
        public var time: ContinuousClock.Instant
        /// The pointer is in the menu bar of its display.
        public var isPointerInMenuBar: Bool
        /// A menu or a new window hanging from the menu bar is on screen (`MenuBarPresentation.isOpen`).
        public var isPresentationOpen: Bool
        /// The frontmost app's process (nil: unknown).
        public var frontmostPID: pid_t?
        /// Any mouse button is held (HID state, `UserMouseButtons`).
        public var isMouseButtonHeld: Bool

        public init(time: ContinuousClock.Instant, isPointerInMenuBar: Bool, isPresentationOpen: Bool,
                    frontmostPID: pid_t?, isMouseButtonHeld: Bool = false) {
            self.time = time
            self.isPointerInMenuBar = isPointerInMenuBar
            self.isPresentationOpen = isPresentationOpen
            self.frontmostPID = frontmostPID
            self.isMouseButtonHeld = isMouseButtonHeld
        }
    }

    public enum Decision: Equatable, Sendable {
        case wait
        case collapse(Reason)
    }

    public enum Reason: String, Equatable, Sendable {
        case presentationClosed = "a menu or popover opened from the menu bar closed"
        case appSwitched = "the frontmost app changed"
    }

    public let timing: Timing
    /// The frontmost app when the icons were revealed.
    private let initialFrontmostPID: pid_t?
    /// The last time the user was busy with the menu bar: the pointer in it, a presentation open, or the start.
    private var lastBusy: ContinuousClock.Instant
    private var sawPresentation = false
    private var isQuiet = false

    /// `start`: when the icons were revealed (the user just clicked the Frost icon); `frontmostPID`: the frontmost
    /// app then.
    public init(start: ContinuousClock.Instant, frontmostPID: pid_t?, timing: Timing = .standard) {
        self.timing = timing
        initialFrontmostPID = frontmostPID
        lastBusy = start
    }

    /// Whether the caller should take a new window baseline before judging the next sample: nothing has happened in
    /// the menu bar for `baselineQuiet`, so windows that appeared meanwhile (a notification banner) are not something
    /// the user opened there. Kept frozen for a while after the pointer leaves the menu bar: a popover may still be on
    /// its way.
    public var acceptsNewBaseline: Bool { isQuiet }

    public mutating func update(_ sample: Sample) -> Decision {
        let now = sample.time
        if sample.isPresentationOpen {
            sawPresentation = true
            lastBusy = now
        } else if sample.isPointerInMenuBar {
            lastBusy = now
        }
        isQuiet = !sample.isPresentationOpen && !sample.isPointerInMenuBar && now - lastBusy >= timing.baselineQuiet
        if sample.isPresentationOpen || sample.isPointerInMenuBar || sample.isMouseButtonHeld { return .wait }
        let away = now - lastBusy
        if sawPresentation, away >= timing.closeGrace { return .collapse(.presentationClosed) }
        if let front = sample.frontmostPID, front != initialFrontmostPID, away >= timing.switchGrace {
            return .collapse(.appSwitched)
        }
        return .wait
    }
}

/// Windows the user opened from the menu bar: menus, and popover-like windows hanging from it (a status item's
/// popover or panel). Used by smart rehide and to tell a click inside such a window from a click elsewhere.
public enum MenuBarPresentation {
    public struct Window: Equatable, Sendable {
        public var windowID: CGWindowID
        public var layer: Int
        public var ownerPID: pid_t?
        /// CG global coordinates (top-left origin).
        public var frame: CGRect

        public init(windowID: CGWindowID, layer: Int, ownerPID: pid_t?, frame: CGRect) {
            self.windowID = windowID
            self.layer = layer
            self.ownerPID = ownerPID
            self.frame = frame
        }
    }

    /// How far below the menu bar a window's top edge may be and still hang from it (popovers leave a small gap for
    /// their arrow).
    public static let attachmentTolerance: CGFloat = 12

    /// Layers of popover-like windows: above normal windows (0), below drag images (500).
    static let presentationLayers = 1..<500

    /// Whether `window` hangs from one of `menuBars` (CG rects of each display's menu bar): not Frost's, above normal
    /// windows, its top edge at that menu bar's bottom (within `attachmentTolerance`) and reaching below it (status
    /// item windows sit inside the menu bar row).
    public static func hangsFromMenuBar(_ window: Window, menuBars: [CGRect], ownPID: pid_t) -> Bool {
        guard window.ownerPID != ownPID, presentationLayers.contains(window.layer) else { return false }
        let frame = window.frame
        return menuBars.contains { bar in
            frame.midX >= bar.minX && frame.midX < bar.maxX
                && frame.minY >= bar.minY && frame.minY <= bar.maxY + attachmentTolerance
                && frame.maxY > bar.maxY + 1
        }
    }

    /// Whether a presentation is open: any menu (as `ItemClicker.isMenuOnScreen`), or a window outside `baseline`
    /// that hangs from the menu bar.
    public static func isOpen(in windows: [Window], baseline: Set<CGWindowID>, menuBars: [CGRect],
                              ownPID: pid_t) -> Bool {
        !openWindows(in: windows, baseline: baseline, menuBars: menuBars, ownPID: ownPID).isEmpty
    }

    /// The windows `isOpen` counts, front to back: what keeps smart rehide waiting (logged when the delay timer
    /// collapses instead).
    public static func openWindows(in windows: [Window], baseline: Set<CGWindowID>, menuBars: [CGRect],
                                   ownPID: pid_t) -> [Window] {
        windows.filter { window in
            window.layer == ItemClicker.menuLayer
                || (!baseline.contains(window.windowID) && hangsFromMenuBar(window, menuBars: menuBars, ownPID: ownPID))
        }
    }

    /// A window for the log: ID, owner, layer and frame (no titles: they can be user content).
    public static func describe(_ window: Window) -> String {
        let f = window.frame
        return "window \(window.windowID) (pid \(window.ownerPID.map(String.init) ?? "?"), layer \(window.layer), "
            + "at \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))"
    }

    /// Whether `point` (CG) is inside a non-menu window hanging from the menu bar: a click there is the user working
    /// in a popover they opened, not a click elsewhere. Menus are left out: picking an entry has always collapsed
    /// right away.
    public static func presentationContains(_ point: CGPoint, windows: [Window], menuBars: [CGRect],
                                            ownPID: pid_t) -> Bool {
        windows.contains { window in
            window.layer != ItemClicker.menuLayer && window.frame.contains(point)
                && hangsFromMenuBar(window, menuBars: menuBars, ownPID: ownPID)
        }
    }

    /// The windows on screen now (front to back).
    public static func currentWindows() -> [Window] {
        ItemClicker.currentOnscreenWindows().map {
            Window(windowID: $0.windowID, layer: $0.layer, ownerPID: $0.ownerPID, frame: $0.frame)
        }
    }
}
