import CoreGraphics
import Testing
@testable import FrostCore

@Suite struct SmartRehideTests {
    /// Fixed timing, independent of `Timing.standard`.
    static let timing = SmartRehide.Timing(closeGrace: .milliseconds(400), switchGrace: .milliseconds(750),
                                           baselineQuiet: .seconds(1))

    let t0 = ContinuousClock.now
    func ms(_ value: Int) -> ContinuousClock.Instant { t0 + .milliseconds(value) }

    func sample(_ time: Int, inBar: Bool = false, open: Bool = false, front: pid_t? = 10,
                held: Bool = false) -> SmartRehide.Sample {
        SmartRehide.Sample(time: ms(time), isPointerInMenuBar: inBar, isPresentationOpen: open, frontmostPID: front,
                           isMouseButtonHeld: held)
    }

    func policy() -> SmartRehide { SmartRehide(start: t0, frontmostPID: 10, timing: Self.timing) }

    @Test func nothingHappensWithoutAPresentationOrAnAppSwitch() {
        var rehide = policy()
        #expect(rehide.update(sample(250, inBar: true)) == .wait)
        #expect(rehide.update(sample(500)) == .wait)
        // Pointer away for a long time, same app in front: left to the delay timer.
        #expect(rehide.update(sample(60_000)) == .wait)
    }

    @Test func aMenuThatClosesCollapsesAfterTheGrace() {
        var rehide = policy()
        #expect(rehide.update(sample(250, inBar: true)) == .wait)
        #expect(rehide.update(sample(500, inBar: true, open: true)) == .wait)
        // The user moves down into the menu for a long time: never while it's open.
        #expect(rehide.update(sample(30_000, open: true)) == .wait)
        // Closed (an entry was picked below the menu bar).
        #expect(rehide.update(sample(30_250)) == .wait)
        #expect(rehide.update(sample(30_399)) == .wait)
        #expect(rehide.update(sample(30_400)) == .collapse(.presentationClosed))
    }

    @Test func aClosedMenuWaitsWhileThePointerStaysInTheMenuBar() {
        var rehide = policy()
        _ = rehide.update(sample(250, inBar: true, open: true))
        // Closed with Esc, the pointer still on the menu bar (maybe about to open another icon's menu).
        #expect(rehide.update(sample(500, inBar: true)) == .wait)
        #expect(rehide.update(sample(10_000, inBar: true)) == .wait)
        // Another menu opens: still waiting.
        #expect(rehide.update(sample(10_250, inBar: true, open: true)) == .wait)
        #expect(rehide.update(sample(10_500, inBar: true)) == .wait)
        // Leaves: the grace counts from the last moment in the menu bar.
        #expect(rehide.update(sample(10_750)) == .wait)
        #expect(rehide.update(sample(10_900)) == .collapse(.presentationClosed))
    }

    @Test func anAppSwitchCollapsesOnceThePointerIsAway() {
        var rehide = policy()
        #expect(rehide.update(sample(250)) == .wait)
        // ⌘-Tab to another app.
        #expect(rehide.update(sample(2000, front: 20)) == .collapse(.appSwitched))
    }

    @Test func anAppSwitchWaitsWhileThePointerIsInTheMenuBar() {
        var rehide = policy()
        // A click on a revealed item activated its app; the pointer is still on the item.
        #expect(rehide.update(sample(250, inBar: true, front: 20)) == .wait)
        #expect(rehide.update(sample(5000, inBar: true, front: 20)) == .wait)
        // Its popover appears as the pointer moves down: it holds.
        #expect(rehide.update(sample(5250, open: true, front: 20)) == .wait)
        #expect(rehide.update(sample(20_000, open: true, front: 20)) == .wait)
        // Popover closed: collapses after the close grace.
        #expect(rehide.update(sample(20_250, front: 20)) == .wait)
        #expect(rehide.update(sample(20_650, front: 20)) == .collapse(.presentationClosed))
    }

    @Test func anAppSwitchRightAfterLeavingTheMenuBarWaitsForThePresentationToAppear() {
        var rehide = policy()
        #expect(rehide.update(sample(250, inBar: true)) == .wait)
        // Clicked an item and moved down at once: the app is in front, its popover not on screen yet.
        #expect(rehide.update(sample(500, front: 20)) == .wait)
        #expect(rehide.update(sample(749, front: 20)) == .wait)
        #expect(rehide.update(sample(900, open: true, front: 20)) == .wait)
        // Without a presentation it would have collapsed at 250 + 750 ms.
        var other = policy()
        _ = other.update(sample(250, inBar: true))
        #expect(other.update(sample(999, front: 20)) == .wait)
        #expect(other.update(sample(1000, front: 20)) == .collapse(.appSwitched))
    }

    @Test func switchingBackToTheOriginalAppIsNotASwitch() {
        var rehide = policy()
        _ = rehide.update(sample(250, inBar: true, front: 20))
        #expect(rehide.update(sample(5000, inBar: true, front: 10)) == .wait)
        #expect(rehide.update(sample(9000, front: 10)) == .wait)
    }

    @Test func anUnknownFrontmostAppIsNotASwitch() {
        var rehide = policy()
        #expect(rehide.update(sample(2000, front: nil)) == .wait)
    }

    @Test func neverCollapsesWhileAButtonIsHeld() {
        var rehide = policy()
        _ = rehide.update(sample(250, open: true))
        #expect(rehide.update(sample(2000, held: true)) == .wait)
        #expect(rehide.update(sample(2250)) == .collapse(.presentationClosed))
        var switched = policy()
        #expect(switched.update(sample(2000, front: 20, held: true)) == .wait)
        #expect(switched.update(sample(2250, front: 20)) == .collapse(.appSwitched))
    }

    @Test func theBaselineIsRefreshedOnlyAfterAQuietPeriod() {
        var rehide = policy()
        // Not yet a full second since the start.
        _ = rehide.update(sample(250))
        #expect(!rehide.acceptsNewBaseline)
        _ = rehide.update(sample(1000))
        #expect(rehide.acceptsNewBaseline)
        // In the menu bar: frozen, and for a second after leaving it (a popover may still be on its way).
        _ = rehide.update(sample(1250, inBar: true))
        #expect(!rehide.acceptsNewBaseline)
        _ = rehide.update(sample(2000))
        #expect(!rehide.acceptsNewBaseline)
        _ = rehide.update(sample(2250))
        #expect(rehide.acceptsNewBaseline)
        _ = rehide.update(sample(2500, open: true))
        #expect(!rehide.acceptsNewBaseline)
    }
}

@Suite struct MenuBarPresentationTests {
    /// One 1728 pt display with a 30 pt menu bar, and a second one to its right with a 24 pt menu bar.
    let menuBars = [CGRect(x: 0, y: 0, width: 1728, height: 30), CGRect(x: 1728, y: 0, width: 1920, height: 24)]
    let ownPID: pid_t = 1

    func window(_ id: CGWindowID, layer: Int = 25, pid: pid_t = 50, _ frame: CGRect) -> MenuBarPresentation.Window {
        MenuBarPresentation.Window(windowID: id, layer: layer, ownerPID: pid, frame: frame)
    }

    @Test func aPopoverHangingFromTheMenuBarIsAPresentation() {
        let popover = window(1, CGRect(x: 1200, y: 33, width: 300, height: 400))
        #expect(MenuBarPresentation.hangsFromMenuBar(popover, menuBars: menuBars, ownPID: ownPID))
        // On the second display, against its own menu bar.
        let other = window(2, layer: 3, CGRect(x: 2000, y: 26, width: 300, height: 200))
        #expect(MenuBarPresentation.hangsFromMenuBar(other, menuBars: menuBars, ownPID: ownPID))
    }

    @Test func statusItemsNormalWindowsFrostAndFarWindowsAreNot() {
        // A status item window: inside the menu bar row, it doesn't reach below it.
        #expect(!MenuBarPresentation.hangsFromMenuBar(window(1, CGRect(x: 1200, y: 0, width: 30, height: 30)),
                                                      menuBars: menuBars, ownPID: ownPID))
        // A normal app window right below the menu bar (layer 0).
        #expect(!MenuBarPresentation.hangsFromMenuBar(window(2, layer: 0, CGRect(x: 0, y: 30, width: 1728, height: 900)),
                                                      menuBars: menuBars, ownPID: ownPID))
        // Frost's own panel.
        #expect(!MenuBarPresentation.hangsFromMenuBar(window(3, pid: ownPID, CGRect(x: 1200, y: 30, width: 300, height: 200)),
                                                      menuBars: menuBars, ownPID: ownPID))
        // A floating window in the middle of the screen.
        #expect(!MenuBarPresentation.hangsFromMenuBar(window(4, layer: 3, CGRect(x: 400, y: 300, width: 300, height: 200)),
                                                      menuBars: menuBars, ownPID: ownPID))
        // A drag image (layer 500).
        #expect(!MenuBarPresentation.hangsFromMenuBar(window(5, layer: 500, CGRect(x: 1200, y: 30, width: 30, height: 40)),
                                                      menuBars: menuBars, ownPID: ownPID))
    }

    @Test func menusAreAlwaysOpenPresentationsAndHangingWindowsOnlyOutsideTheBaseline() {
        let menu = window(1, layer: 101, CGRect(x: 600, y: 400, width: 200, height: 100))
        let popover = window(2, CGRect(x: 1200, y: 32, width: 300, height: 400))
        let normal = window(3, layer: 0, CGRect(x: 0, y: 30, width: 800, height: 600))
        #expect(MenuBarPresentation.isOpen(in: [menu, normal], baseline: [1, 3], menuBars: menuBars, ownPID: ownPID))
        #expect(MenuBarPresentation.isOpen(in: [popover, normal], baseline: [3], menuBars: menuBars, ownPID: ownPID))
        // Already there before (an app's panel that is always shown): not one the user just opened.
        #expect(!MenuBarPresentation.isOpen(in: [popover, normal], baseline: [2, 3], menuBars: menuBars,
                                            ownPID: ownPID))
    }

    @Test func aClickInsideAPopoverIsNotAnOutsideClickButOneInAMenuStillIs() {
        let popover = window(1, CGRect(x: 1200, y: 32, width: 300, height: 400))
        let menu = window(2, layer: 101, CGRect(x: 600, y: 30, width: 200, height: 100))
        let windows = [popover, menu]
        #expect(MenuBarPresentation.presentationContains(CGPoint(x: 1300, y: 200), windows: windows,
                                                          menuBars: menuBars, ownPID: ownPID))
        // Choosing a menu entry collapses as it always did.
        #expect(!MenuBarPresentation.presentationContains(CGPoint(x: 700, y: 60), windows: windows,
                                                           menuBars: menuBars, ownPID: ownPID))
        #expect(!MenuBarPresentation.presentationContains(CGPoint(x: 100, y: 500), windows: windows,
                                                           menuBars: menuBars, ownPID: ownPID))
    }
}
