import CoreGraphics
import Testing
@testable import FrostCore

/// macOS 27: moving relaunched icons back into the sections the user arranged (`ArrangedSectionKeeper`).
@Suite struct ArrangedSectionKeeperTests {
    private let dividers = ArrangedSectionKeeper.Dividers(alwaysHidden: 901, alwaysHiddenPair: 902, hidden: 903,
                                                          hiddenPair: 904, icon: 905)

    private func item(_ id: CGWindowID, x: CGFloat, key: String? = nil, bundle: String? = "com.example.app",
                      width: CGFloat = 30) -> MenuBarItem {
        MenuBarItem(windowID: id, frame: CGRect(x: x, y: 0, width: width, height: 24), isOnScreen: true,
                    windowTitle: "", bundleID: bundle, pid: 100, axDescription: "Icon \(id)",
                    identityKey: key ?? "desc:Icon \(id)")
    }

    private func own(_ id: CGWindowID, x: CGFloat) -> MenuBarItem {
        MenuBarItem(windowID: id, frame: CGRect(x: x, y: 0, width: 8, height: 24), isOnScreen: true,
                    windowTitle: "", bundleID: "dev.frost.Frost", pid: 1, axDescription: nil, identityKey: "own:\(id)")
    }

    /// `AH AH.Pair [hidden band] H H.Pair [visible band] snowflake`, with the dividers at the given x positions.
    private func ownItems(ah: CGFloat = 200, ahPair: CGFloat = 210, h: CGFloat = 400, hPair: CGFloat = 410,
                          icon: CGFloat = 700) -> [MenuBarItem] {
        [own(901, x: ah), own(902, x: ahPair), own(903, x: h), own(904, x: hPair), own(905, x: icon)]
    }

    // MARK: - Bands

    @Test func bandsFollowTheOrderRelativeToFrostsItems() {
        let items = ownItems() + [item(1, x: 100), item(2, x: 300), item(3, x: 500), item(4, x: 800)]
        let bands = ArrangedSectionKeeper.physicalSections(of: items, dividers: dividers)
        #expect(bands == [1: .alwaysHidden, 2: .hidden, 3: .visible, 4: .visible])
    }

    /// An icon squeezed between a divider and its pair is in no band: it can't be told which side it is drawn on, so
    /// a remembered icon there is always moved into its band.
    @Test func iconsBetweenADividerAndItsPairAreInNoBand() {
        let items = ownItems(ah: 200, ahPair: 260, h: 400, hPair: 460)
            + [item(1, x: 215), item(2, x: 415)]
        let bands = ArrangedSectionKeeper.physicalSections(of: items, dividers: dividers)
        #expect(bands == [:])
    }

    @Test func nothingIsDecidedWhenFrostsItemsAreOutOfOrder() {
        // The Hidden divider is left of the Always Hidden one: the bands can't be told apart.
        let swapped = ownItems(ah: 400, ahPair: 410, h: 200, hPair: 210) + [item(1, x: 300)]
        #expect(ArrangedSectionKeeper.physicalSections(of: swapped, dividers: dividers) == nil)
        #expect(ArrangedSectionKeeper.decide(items: swapped, dividers: dividers, checked: [],
                                             remembered: { _ in .hidden }) == nil)
    }

    @Test func nothingIsDecidedWhenOneOfFrostsItemsIsMissing() {
        let items = ownItems().filter { $0.windowID != 904 } + [item(1, x: 300)]
        #expect(ArrangedSectionKeeper.physicalSections(of: items, dividers: dividers) == nil)
    }

    @Test func nothingIsDecidedWhenTheSnowflakeIsLeftOfTheHiddenPair() {
        let items = ownItems(icon: 405) + [item(1, x: 300)]
        #expect(ArrangedSectionKeeper.physicalSections(of: items, dividers: dividers) == nil)
    }

    // MARK: - Deciding

    /// The failure this fixes: a Visible icon re-added at the far left is never drawn and isn't in the Frost Bar.
    @Test func aRelaunchedVisibleIconAtTheFarLeftGoesBackNextToTheSnowflake() {
        let relaunched = item(1, x: 100)
        let items = ownItems() + [relaunched, item(2, x: 300), item(3, x: 500)]
        let remembered: [CGWindowID: MenuBarSection] = [1: .visible, 2: .hidden, 3: .visible]
        let decision = ArrangedSectionKeeper.decide(items: items, dividers: dividers, checked: [2, 3],
                                                    remembered: { remembered[$0.windowID] })
        #expect(decision?.restores.map(\.item.windowID) == [1])
        #expect(decision?.restores.first?.from == .alwaysHidden)
        #expect(decision?.restores.first?.to == .visible)
        #expect(decision?.settled.isEmpty == true)
    }

    @Test func iconsAlreadyInTheirSectionAreSettledWithoutAMove() {
        let items = ownItems() + [item(1, x: 100), item(2, x: 300), item(3, x: 500)]
        let remembered: [CGWindowID: MenuBarSection] = [1: .alwaysHidden, 2: .hidden, 3: .visible]
        let decision = ArrangedSectionKeeper.decide(items: items, dividers: dividers, checked: [],
                                                    remembered: { remembered[$0.windowID] })
        #expect(decision?.restores.isEmpty == true)
        #expect(decision?.settled == [1, 2, 3])
    }

    /// Checked once: an icon the user moved later (or one a failed restore left) is not moved again.
    @Test func checkedIconsAreNeverRestored() {
        let items = ownItems() + [item(1, x: 100)]
        let decision = ArrangedSectionKeeper.decide(items: items, dividers: dividers, checked: [1],
                                                    remembered: { _ in .visible })
        #expect(decision == ArrangedSectionKeeper.Decision())
    }

    /// An icon the user never arranged counts as Visible wherever it is (`ArrangedLayout`): nothing to restore.
    @Test func neverArrangedIconsAreLeftWhereTheyAre() {
        let items = ownItems() + [item(1, x: 100)]
        let decision = ArrangedSectionKeeper.decide(items: items, dividers: dividers, checked: [],
                                                    remembered: { _ in nil })
        #expect(decision?.restores.isEmpty == true)
        #expect(decision?.settled == [1])
    }

    @Test func iconsBetweenADividerAndItsPairAreMovedIntoTheirBand() {
        let items = ownItems(h: 400, hPair: 460) + [item(1, x: 415)]
        let decision = ArrangedSectionKeeper.decide(items: items, dividers: dividers, checked: [],
                                                    remembered: { _ in .hidden })
        #expect(decision?.restores.map(\.item.windowID) == [1])
        #expect(decision?.restores.first?.from == nil)
    }

    /// Two current icons sharing an identity (an old one still lingering next to the re-created one): neither is
    /// moved nor checked until it is unique again.
    @Test func sharedIdentitiesWait() {
        let items = ownItems() + [item(1, x: 100, key: "desc:Same"), item(2, x: 500, key: "desc:Same")]
        let decision = ArrangedSectionKeeper.decide(items: items, dividers: dividers, checked: [],
                                                    remembered: { _ in .hidden })
        #expect(decision == ArrangedSectionKeeper.Decision())
    }

    @Test func unresolvedIconsWait() {
        let items = ownItems() + [item(1, x: 100, bundle: nil)]
        let triage = ArrangedSectionKeeper.triage(items: items, own: dividers.all, checked: [],
                                                  remembered: { _ in .hidden })
        #expect(triage == ArrangedSectionKeeper.Triage())
    }

    /// Frost's own interrupted move puts such an icon back into its exact slot (`PendingReturn`); it waits for that.
    @Test func iconsWithAPendingReturnWait() {
        let relaunched = item(1, x: 100)
        let items = ownItems() + [relaunched]
        let decision = ArrangedSectionKeeper.decide(items: items, dividers: dividers, checked: [],
                                                    skipping: [relaunched.identity!], remembered: { _ in .visible })
        #expect(decision == ArrangedSectionKeeper.Decision())
    }

    @Test func immovableIconsAndTheOverflowChevronAreSettled() {
        let clock = MenuBarItem(windowID: 1, frame: CGRect(x: 800, y: 0, width: 60, height: 24), isOnScreen: true,
                                windowTitle: "", bundleID: "com.apple.controlcenter", pid: 50, axDescription: "Clock",
                                axIdentifier: "com.apple.menuextra.clock", identityKey: "id:com.apple.menuextra.clock")
        let chevron = MenuBarItem(windowID: 2, frame: CGRect(x: 150, y: 0, width: 20, height: 24), isOnScreen: true,
                                  windowTitle: "", bundleID: "com.apple.MenuBarAgent", pid: 51,
                                  axDescription: "Show more menu bar items", identityKey: "desc:chevron")
        let items = ownItems() + [clock, chevron]
        let triage = ArrangedSectionKeeper.triage(items: items, own: dividers.all, checked: [],
                                                  remembered: { _ in .hidden })
        #expect(triage.candidates.isEmpty)
        #expect(triage.settled.contains(1))
    }

    /// The triage needs no revealed bar: it decides whether a reveal is needed at all.
    @Test func triageListsOnlyRememberedFirstSeenIcons() {
        let items = ownItems() + [item(1, x: 100), item(2, x: 300), item(3, x: 500)]
        let remembered: [CGWindowID: MenuBarSection] = [1: .visible, 3: .hidden]
        let triage = ArrangedSectionKeeper.triage(items: items, own: dividers.all, checked: [3],
                                                  remembered: { remembered[$0.windowID] })
        #expect(triage.candidates.map(\.windowID) == [1])
        #expect(triage.settled == [2])
    }

    @Test func restoresAreListedLeftToRight() {
        let items = ownItems() + [item(2, x: 500), item(1, x: 100)]
        let decision = ArrangedSectionKeeper.decide(items: items, dividers: dividers, checked: [],
                                                    remembered: { _ in .hidden })
        #expect(decision?.restores.map(\.item.windowID) == [1, 2])
    }

    // MARK: - Aligning the dividers

    /// The ordering bug this guards against: a relaunched (or new) icon at the far left counts as Visible, and
    /// aligning the Hidden divider against it dragged the divider to the far left, revealing every Hidden icon.
    @Test func theHiddenDividerIgnoresVisibleIconsLeftOfTheAlwaysHiddenPair() {
        let stray = item(1, x: 100), first = item(2, x: 450), second = item(3, x: 550)
        let layout: MenuBarLayout = [.visible: [stray, first, second], .hidden: [item(4, x: 300)], .alwaysHidden: []]
        let anchor = ArrangedSectionKeeper.hiddenAlignmentAnchor(in: layout, afterX: 218, beforeX: 700)
        #expect(anchor?.windowID == 2)
    }

    @Test func theHiddenDividerGoesAgainstTheSnowflakeWithoutVisibleIcons() {
        let layout: MenuBarLayout = [.visible: [item(1, x: 100), item(2, x: 800)], .hidden: [], .alwaysHidden: []]
        #expect(ArrangedSectionKeeper.hiddenAlignmentAnchor(in: layout, afterX: 218, beforeX: 700) == nil)
    }

    // MARK: - Destinations

    @Test func visibleGoesImmediatelyLeftOfTheSnowflake() {
        let items = ownItems() + [item(1, x: 500)]
        let bands = ArrangedSectionKeeper.physicalSections(of: items, dividers: dividers) ?? [:]
        #expect(ArrangedSectionKeeper.destination(for: .visible, items: items, bands: bands, dividers: dividers)
                    == .leftOf(905))
    }

    /// A populated band is joined after its last icon, like a layout editor drop at the end of the band.
    @Test func aPopulatedBandIsJoinedAfterItsLastIcon() {
        let items = ownItems() + [item(1, x: 50), item(2, x: 120), item(3, x: 250), item(4, x: 330)]
        let bands = ArrangedSectionKeeper.physicalSections(of: items, dividers: dividers) ?? [:]
        #expect(ArrangedSectionKeeper.destination(for: .hidden, items: items, bands: bands, dividers: dividers)
                    == .rightOf(4))
        #expect(ArrangedSectionKeeper.destination(for: .alwaysHidden, items: items, bands: bands, dividers: dividers)
                    == .rightOf(2))
    }

    @Test func anEmptyBandIsJoinedAgainstItsDivider() {
        let items = ownItems() + [item(1, x: 500)]
        let bands = ArrangedSectionKeeper.physicalSections(of: items, dividers: dividers) ?? [:]
        #expect(ArrangedSectionKeeper.destination(for: .hidden, items: items, bands: bands, dividers: dividers)
                    == .leftOf(903))
        #expect(ArrangedSectionKeeper.destination(for: .alwaysHidden, items: items, bands: bands, dividers: dividers)
                    == .leftOf(901))
    }

    /// An icon that is itself out of place (still to be moved) is no anchor: it is about to leave the band.
    @Test func outOfPlaceIconsAreNoAnchors() {
        let items = ownItems() + [item(1, x: 250), item(2, x: 330)]
        let bands = ArrangedSectionKeeper.physicalSections(of: items, dividers: dividers) ?? [:]
        #expect(ArrangedSectionKeeper.destination(for: .hidden, items: items, bands: bands, dividers: dividers,
                                                  excluding: [2]) == .rightOf(1))
        #expect(ArrangedSectionKeeper.destination(for: .hidden, items: items, bands: bands, dividers: dividers,
                                                  excluding: [1, 2]) == .leftOf(903))
    }

    // MARK: - New apps' icons

    /// A new app's icon in the Always Hidden band would be drawn nowhere and listed nowhere (it counts as Visible
    /// until arranged): it goes to Hidden, as on macOS 26, and is remembered there.
    @Test func aNewIconInTheAlwaysHiddenBandGoesToHidden() {
        let items = ownItems() + [item(1, x: 100)]
        let decision = ArrangedSectionKeeper.decide(items: items, dividers: dividers, checked: [],
                                                    remembered: { _ in nil }, isNew: { _ in true })
        #expect(decision?.restores.map(\.item.windowID) == [1])
        #expect(decision?.restores.first?.to == .hidden)
        #expect(decision?.restores.first?.from == .alwaysHidden)
        #expect(decision?.restores.first?.isNew == true)
        #expect(decision?.newItems.map(\.section) == [.hidden])
        #expect(decision?.settled.isEmpty == true)
    }

    /// Between a divider and its pair a new icon is in no band: it is moved into Hidden too.
    @Test func aNewIconBetweenADividerAndItsPairGoesToHidden() {
        let items = ownItems(ah: 200, ahPair: 260) + [item(1, x: 215)]
        let decision = ArrangedSectionKeeper.decide(items: items, dividers: dividers, checked: [],
                                                    remembered: { _ in nil }, isNew: { _ in true })
        #expect(decision?.restores.map(\.to) == [.hidden])
        #expect(decision?.restores.first?.from == nil)
    }

    /// A new icon the bar already has in Hidden or Visible stays where it is and is remembered there, so the Frost Bar
    /// and the layout editor show it where it is drawn.
    @Test func aNewIconInHiddenOrVisibleIsRememberedWhereItIs() {
        let items = ownItems() + [item(1, x: 300), item(2, x: 500)]
        let decision = ArrangedSectionKeeper.decide(items: items, dividers: dividers, checked: [],
                                                    remembered: { _ in nil }, isNew: { _ in true })
        #expect(decision?.restores.isEmpty == true)
        #expect(decision?.settled == [1, 2])
        let sections = Dictionary(uniqueKeysWithValues: (decision?.newItems ?? []).map { ($0.item.windowID, $0.section) })
        #expect(sections == [1: .hidden, 2: .visible])
    }

    /// Only new icons are taken care of: a known icon that was never arranged stays as it is (settled, unrecorded).
    @Test func knownNeverArrangedIconsStayUnrecorded() {
        let items = ownItems() + [item(1, x: 100), item(2, x: 120)]
        let decision = ArrangedSectionKeeper.decide(items: items, dividers: dividers, checked: [],
                                                    remembered: { _ in nil }, isNew: { $0.windowID == 2 })
        #expect(decision?.restores.map(\.item.windowID) == [2])
        #expect(decision?.settled == [1])
        #expect(decision?.newItems.map(\.item.windowID) == [2])
    }

    /// New icons need the bar read (a reveal): triage lists them as candidates; a remembered icon is never new.
    @Test func triageListsNewIconsAsCandidates() {
        let items = ownItems() + [item(1, x: 100), item(2, x: 300), item(3, x: 500)]
        let triage = ArrangedSectionKeeper.triage(items: items, own: dividers.all, checked: [],
                                                  remembered: { $0.windowID == 3 ? .visible : nil },
                                                  isNew: { $0.windowID != 1 })
        #expect(Set(triage.candidates.map(\.windowID)) == [2, 3])
        #expect(triage.settled == [1])
        let newOnes = ArrangedSectionKeeper.decide(items: items, dividers: dividers, checked: [],
                                                   remembered: { $0.windowID == 3 ? .visible : nil },
                                                   isNew: { $0.windowID != 1 })?.newItems.map(\.item.windowID)
        #expect(newOnes == [2])
    }

    /// Shared or unresolved identities wait, new or not.
    @Test func newIconsWithSharedIdentitiesWait() {
        let items = ownItems() + [item(1, x: 100, key: "same"), item(2, x: 120, key: "same")]
        let decision = ArrangedSectionKeeper.decide(items: items, dividers: dividers, checked: [],
                                                    remembered: { _ in nil }, isNew: { _ in true })
        #expect(decision == ArrangedSectionKeeper.Decision())
    }
}
