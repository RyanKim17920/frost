import Foundation
import Testing
@testable import FrostCore

struct FrostBarIconClickTests {
    private let now = ContinuousClock.now

    private func decide(_ phase: FrostBarIconClick.Phase, option: Bool = false,
                        showingAlwaysHidden: Bool = false) -> FrostBarIconClick.Action {
        FrostBarIconClick.decide(phase: phase, option: option, showingAlwaysHidden: showingAlwaysHidden, now: now)
    }

    @Test func closedPanelOpens() {
        #expect(decide(.closed) == .open(showAlwaysHidden: false))
        #expect(decide(.closed, option: true) == .open(showAlwaysHidden: true))
    }

    /// The open waits for a lingering item to move back (the panel isn't on screen yet): a second click must not close
    /// (and cancel) an open the user can't see yet.
    @Test func clickWhileOpeningKeepsOpening() {
        let since = now - .milliseconds(800)
        #expect(decide(.opening(since: since)) == .keepOpening(showAlwaysHidden: nil))
        #expect(decide(.opening(since: since), option: true) == .keepOpening(showAlwaysHidden: true))
    }

    /// An open that has waited this long is stuck behind something that doesn't end by itself (a previous click
    /// forward still waiting for its presentation): the user's next click must end that wait instead of being
    /// swallowed like every click before it.
    @Test func clickOnAStalledOpenEndsTheWait() {
        let since = now - FrostBarIconClick.stalledOpening
        #expect(decide(.opening(since: since)) == .endStalledWait(showAlwaysHidden: nil))
        #expect(decide(.opening(since: now - .seconds(30)), option: true) == .endStalledWait(showAlwaysHidden: true))
    }

    /// A click right after the panel appeared was made before the user could see it.
    @Test func clickJustAfterPresentingIsIgnored() {
        let shown = now - .milliseconds(100)
        #expect(decide(.presented(at: shown)) == .keepOpening(showAlwaysHidden: nil))
        #expect(decide(.presented(at: shown), option: true) == .keepOpening(showAlwaysHidden: true))
    }

    @Test func clickOnShownPanelCloses() {
        let shown = now - FrostBarIconClick.reactionGrace
        #expect(decide(.presented(at: shown)) == .close)
        #expect(decide(.presented(at: now - .seconds(5))) == .close)
    }

    @Test func optionClickOnShownPanelTogglesAlwaysHidden() {
        let shown = now - .seconds(5)
        #expect(decide(.presented(at: shown), option: true) == .setAlwaysHidden(true))
        #expect(decide(.presented(at: shown), option: true, showingAlwaysHidden: true) == .setAlwaysHidden(false))
    }
}

struct FrostBarResignKeyTests {
    private let now = ContinuousClock.now

    /// Losing key focus right after appearing is the system settling focus (e.g. after a switch to another desktop),
    /// not the user switching away: closing then made the click that opened the panel look like it did nothing.
    @Test func resigningKeyRightAfterAppearingKeepsThePanel() {
        #expect(!FrostBarIconClick.closesOnResignKey(shownAt: now - .milliseconds(50), now: now))
        #expect(!FrostBarIconClick.closesOnResignKey(shownAt: now - .milliseconds(900), now: now))
        #expect(!FrostBarIconClick.closesOnResignKey(shownAt: nil, now: now))
    }

    @Test func resigningKeyLaterCloses() {
        #expect(FrostBarIconClick.closesOnResignKey(shownAt: now - FrostBarIconClick.focusChangeGrace, now: now))
        #expect(FrostBarIconClick.closesOnResignKey(shownAt: now - .seconds(4), now: now))
    }

    /// The panel is on every Space: an open in progress continues, and a Space change reported right after it appeared
    /// is the late notice of the desktop switch the user made before clicking.
    @Test func spaceChangeDuringOrJustAfterOpeningKeepsThePanel() {
        #expect(!FrostBarIconClick.closesOnSpaceChange(shownAt: nil, now: now))
        #expect(!FrostBarIconClick.closesOnSpaceChange(shownAt: now - .milliseconds(200), now: now))
    }

    @Test func spaceChangeWhileInUseCloses() {
        #expect(FrostBarIconClick.closesOnSpaceChange(shownAt: now - FrostBarIconClick.focusChangeGrace, now: now))
        #expect(FrostBarIconClick.closesOnSpaceChange(shownAt: now - .seconds(10), now: now))
    }
}

struct IconClickWhileEditingTests {
    /// The user is working in the layout editor: the menu bar already shows every icon, and taking it out of editing
    /// would pull the editor's state from under them.
    @Test func editorInUseKeepsTheMenuBar() {
        #expect(IconClickWhileEditing.decide(editorWindowIsKey: true) == .ignore)
    }

    /// The Settings window was left open on the Layout tab behind other windows: the editor yields the menu bar until
    /// its window is used again, and the click does what it always does.
    @Test func editorInTheBackgroundYields() {
        #expect(IconClickWhileEditing.decide(editorWindowIsKey: false) == .yieldEditor)
    }
}

struct LingerReturnAnchorTests {
    @Test func iconTakesTheRightEdgeOfItsNeighbor() {
        let icon = CGRect(x: 1390, y: 0, width: 30, height: 24)
        let item = CGRect(x: 1424, y: 0, width: 36, height: 24)
        #expect(LingerReturnAnchor.iconMaxX(icon: icon, item: item) == 1460)
    }

    @Test func notTheNeighborGivesNoPrediction() {
        let icon = CGRect(x: 1390, y: 0, width: 30, height: 24)
        #expect(LingerReturnAnchor.iconMaxX(icon: icon, item: CGRect(x: 1500, y: 0, width: 36, height: 24)) == nil)
        #expect(LingerReturnAnchor.iconMaxX(icon: icon, item: CGRect(x: 1300, y: 0, width: 36, height: 24)) == nil)
        #expect(LingerReturnAnchor.iconMaxX(icon: icon, item: CGRect(x: 1424, y: 0, width: 0, height: 24)) == nil)
    }
}
