import CoreGraphics

/// macOS 27: puts an icon its app re-added (a relaunch) back into the section the user arranged it in, and gives a new
/// app's icon a section.
///
/// On 27 the sections are the arrangement (`ArrangedLayout`), not something read from the bar, so an icon the system
/// re-adds somewhere else is still listed in its section while the bar draws it elsewhere: a Hidden icon that lands in
/// the Visible band is drawn, a Visible one that lands at the far left (the first free slot of the trailing area, left
/// of the Always Hidden divider) is never drawn and is not in the Frost Bar either. Where the bar really has an icon is
/// only readable while every icon is drawn (`SectionController.revealingForMove`): then the order the bar reports
/// relative to Frost's own items is reliable (the same order `ItemMover.isSatisfiedOn27` verifies a move with).
///
/// - **Checked once**: an icon is checked when its window first appears. On 27 window IDs are synthesized from the
///   owner's bundle ID, identity key and pid (`AXMenuBarInventory`), so a relaunch is a new window; Frost's own launch
///   checks every icon once. After that only the user moves it (never fight the user).
/// - **Remembered and new icons**: an icon the user never arranged counts as Visible wherever it is (`ArrangedLayout`)
///   and is left alone, unless it is a new app's (`isNew`): that one is remembered in the band the bar has it in,
///   except the Always Hidden band (drawn nowhere, listed nowhere), from which it goes to Hidden, as on macOS 26
///   (`NewItemPlacement`).
/// - **Trust**: nothing is decided unless Frost's own items are in the order they are placed in,
///   `AH < AH.Pair < H < H.Pair < snowflake`; otherwise the bands can't be told apart.
/// - **Ambiguity**: icons whose identity is unresolved or shared by several current icons wait (unchecked).
public enum ArrangedSectionKeeper {
    /// Frost's own items on 27 (window IDs synthesized from their autosave names, `AXMenuBarInventory.ownWindowID`).
    public struct Dividers: Hashable, Sendable {
        public let alwaysHidden: CGWindowID
        public let alwaysHiddenPair: CGWindowID
        public let hidden: CGWindowID
        public let hiddenPair: CGWindowID
        public let icon: CGWindowID

        public init(alwaysHidden: CGWindowID, alwaysHiddenPair: CGWindowID, hidden: CGWindowID,
                    hiddenPair: CGWindowID, icon: CGWindowID) {
            self.alwaysHidden = alwaysHidden
            self.alwaysHiddenPair = alwaysHiddenPair
            self.hidden = hidden
            self.hiddenPair = hiddenPair
            self.icon = icon
        }

        /// Left to right, as Frost places them.
        public var ordered: [CGWindowID] { [alwaysHidden, alwaysHiddenPair, hidden, hiddenPair, icon] }
        public var all: Set<CGWindowID> { Set(ordered) }
    }

    /// The band the bar has each icon in, read from a revealed bar: left of the Always Hidden divider is Always Hidden,
    /// between its pair and the Hidden divider is Hidden, right of the Hidden pair is Visible (also right of the
    /// snowflake: the system items, or an icon Frost moved out for a click). An icon between a divider and its pair is
    /// in no band (absent from the result). Frost's own items are absent too.
    ///
    /// Returns nil when Frost's own items are missing or out of order: then the bands can't be told apart.
    public static func physicalSections(of items: [MenuBarItem], dividers: Dividers) -> [CGWindowID: MenuBarSection]? {
        let byID = Dictionary(items.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { a, _ in a })
        let own = dividers.ordered.compactMap { byID[$0] }
        guard own.count == dividers.ordered.count, own.allSatisfy({ $0.width > 0 }),
              zip(own, own.dropFirst()).allSatisfy({ $0.midX < $1.midX })
        else { return nil }
        let (ah, ahPair, h, hPair) = (own[0].midX, own[1].midX, own[2].midX, own[3].midX)
        var result: [CGWindowID: MenuBarSection] = [:]
        for item in items where !dividers.all.contains(item.windowID) {
            let x = item.frame.midX
            if x < ah {
                result[item.windowID] = .alwaysHidden
            } else if x > ahPair, x < h {
                result[item.windowID] = .hidden
            } else if x > hPair {
                result[item.windowID] = .visible
            }
        }
        return result
    }

    /// The first-seen icons to check, sorted out without looking at the bar.
    public struct Triage: Equatable, Sendable {
        /// Remembered and new icons whose band has to be read from a revealed bar.
        public var candidates: [MenuBarItem] = []
        /// Icons that need nothing whatever the bar says (never arranged, immovable, the overflow chevron): checked
        /// now.
        public var settled: Set<CGWindowID> = []
    }

    /// Sorts out the icons not checked yet (`checked`).
    ///
    /// - Parameters:
    ///   - own: Frost's own items (never checked).
    ///   - skipping: identities with a pending return (`SectionKeeper.pendingReturns`): Frost's own interrupted move
    ///     puts them back into their exact slot; they wait until that is done.
    ///   - remembered: the section the user arranged an icon in, nil when never told.
    ///   - isNew: whether a never-arranged icon is a new app's (`ItemMemoryStore.isNewOnArrangedBar`).
    public static func triage(items: [MenuBarItem], own: Set<CGWindowID>, checked: Set<CGWindowID>,
                              skipping: Set<ItemIdentity> = [],
                              remembered: (MenuBarItem) -> MenuBarSection?,
                              isNew: (MenuBarItem) -> Bool = { _ in false }) -> Triage {
        let others = items.filter { !own.contains($0.windowID) }
        let counts = Dictionary(others.compactMap(\.identity).map { ($0, 1) }, uniquingKeysWith: +)
        var triage = Triage()
        for item in others where !checked.contains(item.windowID) {
            if SystemItemRules.isOverflowChevron(bundleID: item.bundleID, axDescription: item.axDescription)
                || !item.isMovable {
                triage.settled.insert(item.windowID)
                continue
            }
            guard let identity = item.identity, counts[identity, default: 0] == 1,
                  !skipping.contains(identity) else { continue }
            if remembered(item) == nil, !isNew(item) {
                triage.settled.insert(item.windowID)
            } else {
                triage.candidates.append(item)
            }
        }
        return triage
    }

    /// An icon to move back into the section the user arranged it in.
    public struct Restore: Equatable, Sendable {
        public let item: MenuBarItem
        public let identity: ItemIdentity
        /// The band the bar has it in (nil: between a divider and its pair).
        public let from: MenuBarSection?
        public let to: MenuBarSection
        /// A new app's icon (also listed in `Decision.newItems`), not one going back to its arranged section.
        public let isNew: Bool

        public init(item: MenuBarItem, identity: ItemIdentity, from: MenuBarSection?, to: MenuBarSection,
                    isNew: Bool = false) {
            self.item = item
            self.identity = identity
            self.from = from
            self.to = to
            self.isNew = isNew
        }
    }

    /// A new app's icon and the section to remember it in.
    public struct NewItem: Equatable, Sendable {
        public let item: MenuBarItem
        public let identity: ItemIdentity
        public let section: MenuBarSection

        public init(item: MenuBarItem, identity: ItemIdentity, section: MenuBarSection) {
            self.item = item
            self.identity = identity
            self.section = section
        }
    }

    public struct Decision: Equatable, Sendable {
        /// Icons to move back, left to right; the caller marks each as checked once the move was attempted.
        public var restores: [Restore] = []
        /// Icons that need no move (already in their section, or no move is ever needed): checked now.
        public var settled: Set<CGWindowID> = []
        /// New apps' icons and the section each goes into (left to right): where the bar has it, or Hidden for one
        /// in the Always Hidden band or in no band (also in `restores`, to be moved there).
        public var newItems: [NewItem] = []
    }

    /// Decides against a revealed bar (`items` with the frames read while every icon is drawn). Returns nil when
    /// Frost's own items are out of order (`physicalSections`): nothing is decided and nothing is checked.
    public static func decide(items: [MenuBarItem], dividers: Dividers, checked: Set<CGWindowID>,
                              skipping: Set<ItemIdentity> = [],
                              remembered: (MenuBarItem) -> MenuBarSection?,
                              isNew: (MenuBarItem) -> Bool = { _ in false }) -> Decision? {
        guard let bands = physicalSections(of: items, dividers: dividers) else { return nil }
        let triage = triage(items: items, own: dividers.all, checked: checked, skipping: skipping,
                            remembered: remembered, isNew: isNew)
        var decision = Decision(settled: triage.settled)
        for item in triage.candidates.sorted(by: { $0.frame.minX < $1.frame.minX }) {
            guard let identity = item.identity else { continue }
            let band = bands[item.windowID]
            guard let target = remembered(item) else {
                // A new app's icon: remembered where the bar has it, except out of the Always Hidden band.
                switch band {
                case .hidden?, .visible?:
                    decision.settled.insert(item.windowID)
                    decision.newItems.append(NewItem(item: item, identity: identity, section: band ?? .hidden))
                case .alwaysHidden?, nil:
                    decision.restores.append(Restore(item: item, identity: identity, from: band, to: .hidden,
                                                     isNew: true))
                    decision.newItems.append(NewItem(item: item, identity: identity, section: .hidden))
                }
                continue
            }
            if band == target {
                decision.settled.insert(item.windowID)
            } else {
                decision.restores.append(Restore(item: item, identity: identity, from: band, to: target))
            }
        }
        return decision
    }

    /// The icon the Hidden divider pair is aligned against (`SectionController.alignAccessibilityBoundaries`): the
    /// leftmost Visible icon of `layout` between the Always Hidden pair (`afterX`, its right edge) and the snowflake
    /// (`beforeX`, its left edge); nil: none, the divider goes against the snowflake.
    ///
    /// Icons left of the Always Hidden pair don't count. An icon the system re-added at the far left (a relaunch, a new
    /// app: both count as Visible until moved) would otherwise make the Hidden divider be dragged all the way there,
    /// leaving every Hidden icon on its visible side.
    public static func hiddenAlignmentAnchor(in layout: MenuBarLayout, afterX: CGFloat,
                                             beforeX: CGFloat) -> MenuBarItem? {
        layout[.visible, default: []]
            .filter { $0.frame.minX > afterX && $0.frame.minX < beforeX }
            .min { $0.frame.minX < $1.frame.minX }
    }

    /// Where an icon goes to rejoin `section` in a revealed bar: after the last icon the bar has in that band, like a
    /// layout editor drop at the end of a populated band (27 re-places a divider wherever it fits, so a drop against
    /// the divider can land at the front of the band); against the band's divider when it is empty; Visible goes
    /// immediately left of the snowflake, which stays next to the system items.
    ///
    /// - Parameter excluding: icons that are themselves out of place (still to be moved): not used as anchors.
    public static func destination(for section: MenuBarSection, items: [MenuBarItem],
                                   bands: [CGWindowID: MenuBarSection], dividers: Dividers,
                                   excluding: Set<CGWindowID> = []) -> MoveDestination {
        switch section {
        case .visible:
            return .leftOf(dividers.icon)
        case .hidden, .alwaysHidden:
            let last = items
                .filter { bands[$0.windowID] == section && $0.isMovable && !excluding.contains($0.windowID)
                    && !SystemItemRules.isOverflowChevron(bundleID: $0.bundleID, axDescription: $0.axDescription) }
                .max { $0.frame.midX < $1.frame.midX }
            if let last { return .rightOf(last.windowID) }
            return .leftOf(section == .hidden ? dividers.hidden : dividers.alwaysHidden)
        }
    }
}
