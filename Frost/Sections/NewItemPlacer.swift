import AppKit
import FrostCore
import Observation

/// Places icons the system adds to the menu bar: moves new apps' icons from the Always Hidden section to the Hidden
/// section (rules in `NewItemPlacement`), and moves an icon its app re-added in another section back into the section
/// the user keeps it in (rules in `SectionKeeper`).
///
/// A new icon has no Preferred Position, so the system places it leftmost of all status items, i.e. left of the AH
/// separator, where the user can't see it in the menu bar or in the Frost Bar (without ⌥). Seen icons (`ItemIdentity`)
/// are persisted in UserDefaults; the first successful scan marks every current icon as seen. On Frost's very first run,
/// the icons already in Always Hidden are moved to Hidden instead (see `NewItemPlacement`).
///
/// An app whose icon has no stable autosave name (or whose saved position is lost) gets it re-added the same way when it
/// relaunches. The section of every icon is remembered (persisted, `SectionKeeper`): seeded from what Frost sees, and
/// updated when the user moves an icon (a layout editor drop reports it through `recordDrop`; a ⌘-drag in the menu bar is
/// seen as the same window changing section without Frost moving it). When a window Frost hasn't seen in this run shows
/// up in another section, it is moved back, unless the user turned "Keep icons in their sections" off.
///
/// Identities are derived from Accessibility attributes (`ItemIdentityKey`), so all of this works with Accessibility
/// alone. Data persisted by versions that keyed items by window title (Screen Recording) is migrated as items are seen
/// (`IdentityMigration`); the window title last seen with each identity is kept as an extra signal for that. What is
/// remembered, its persistence and that migration live in `ItemMemoryStore` (FrostCore).
///
/// Observes only when the layout is trustworthy: Accessibility granted, not editing, no move transaction, no mouse
/// button held (`UserMouseButtons`), and neither separator under the notch (collapsed or expanded). Moves only when the
/// user won't be disturbed: collapsed, user present, the Frost Bar closed and not forwarding a click (`isPaused`).
/// Retries later when moving isn't convenient (checked again before each item of a batch); a failed move is only logged
/// (no retries).
///
/// On macOS 27 it migrates remembered identities, recovers returns loaded at launch, and moves icons the user arranged
/// back into their sections when their app re-adds them elsewhere (`keepArrangedSections`, `ArrangedSectionKeeper`).
/// A new app's icon (`ItemMemoryStore.isNewOnArrangedBar`) is checked in the same reveal: remembered in the band the
/// bar has it in, or moved to Hidden from the Always Hidden band, as on macOS 26. Other never-arranged icons count as
/// Visible wherever they are (`ArrangedLayout`).
@MainActor
final class NewItemPlacer {
    private let scanner: MenuBarItemScanner
    private let mover: ItemMover
    private let sections: SectionController
    private let permissions: PermissionsService
    private let preferences: Preferences
    private let presence: UserPresenceMonitor
    /// Whether the window-list placement of new icons (`NewItemPlacement`) and the macOS 26 section keeping
    /// (`SectionKeeper`) are available: macOS 26 only. On 27 relaunched and new icons are handled from a revealed bar by
    /// `keepArrangedSections` instead.
    private let canMoveItems: Bool

    /// Called by SectionController when it first writes the AH seed.
    static func markFirstRun(defaults: UserDefaults) {
        ItemMemoryStore.markFirstRun(defaults: defaults)
    }

    /// First run: existing icons are still in Always Hidden and will move to Hidden once Accessibility is granted
    /// (onboarding shows a note based on this). Not observable: onboarding re-reads it when permissions change
    /// (the first decision only happens once Accessibility is granted).
    var isFirstRunPlacementPending: Bool { store.isFirstRunPlacementPending }
    private static let debounce: Duration = .milliseconds(500)
    private static let retryDelay: Duration = .seconds(2)
    /// At most this many moves per move transaction; the rest follow after `retryDelay`, so a long batch (e.g. at login)
    /// never holds the mover for long.
    private static let maxMovesPerBatch = 5

    /// Seen icons, remembered sections, titles and pending returns (persisted).
    private let store: ItemMemoryStore
    /// Windows already handled during this run (see `NewItemPlacement.decide`).
    private var considered: Set<CGWindowID> = []
    /// Identities already logged as ambiguous (logged once each).
    private var loggedAmbiguous: Set<ItemIdentity> = []
    /// A full ownership read happened before seeding (otherwise most icons have no owner yet and seeding is incomplete).
    private var refreshedForSeeding = false
    private var evaluateTask: Task<Void, Never>?
    /// Placement waits while this is true (the Frost Bar is open: moving items would rearrange it under the user's
    /// pointer; or it is forwarding a click, which waits for the mover and would otherwise be starved by the rest of a
    /// batch). Set by the app delegate.
    var isPaused: () -> Bool = { false }

    init(scanner: MenuBarItemScanner, mover: ItemMover, sections: SectionController, permissions: PermissionsService,
         preferences: Preferences, presence: UserPresenceMonitor, canMoveItems: Bool = true,
         defaults: UserDefaults = .standard) {
        self.canMoveItems = canMoveItems
        self.scanner = scanner
        self.mover = mover
        self.sections = sections
        self.permissions = permissions
        self.preferences = preferences
        self.presence = presence
        store = ItemMemoryStore(defaults: defaults)
    }

    func start() {
        observe()
        schedule(after: Self.debounce)
    }

    /// Re-decides (debounced) when the scan results, section state, permissions, presence or the setting change.
    private func observe() {
        withObservationTracking {
            _ = scanner.items
            _ = sections.state
            _ = sections.isEditing
            _ = permissions.canManageItems
            _ = presence.isAway
            _ = preferences.keepItemSections
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.schedule(after: Self.debounce)
                self.observe()
            }
        }
    }

    private func schedule(after delay: Duration) {
        evaluateTask?.cancel()
        evaluations &+= 1
        let evaluation = evaluations
        isIdle = false
        evaluateTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.evaluate()
            // Idle unless the decision scheduled another one (a retry, the rest of a batch) or a newer one replaced it.
            if self?.evaluations == evaluation { self?.isIdle = true }
        }
    }

    /// No decision is pending or running: the background capture of items behind the notch waits for this, so it
    /// never moves an item while new-item placement or the section memory is about to look at or move items.
    private(set) var isIdle = true
    private var evaluations = 0

    /// A move to make: a new icon to Hidden, or a re-added icon back to its remembered section (`restore`).
    private struct Placement {
        enum Kind { case new, restore }
        let item: MenuBarItem
        let section: MenuBarSection
        let kind: Kind
        var restore: SectionKeeper.Restore?

        /// Where to move the icon, against the current `layout` (earlier moves of the batch changed it): a pending
        /// return's exact slot while its neighbours are there, otherwise the section's boundary.
        func destination(in layout: MenuBarLayout, controls: FrostControlWindows) -> MoveDestination {
            restore?.destination(in: layout, controls: controls)
                ?? SectionKeeper.destination(for: section, controls: controls)
        }
    }

    private func evaluate() async {
        guard permissions.canManageItems else { return }
        // The seen set is completed from a full ownership read (on 27 once per launch, `seedArrangedBaseline`).
        if store.known == nil || !canMoveItems, !refreshedForSeeding {
            await scanner.refreshOwnership()
            refreshedForSeeding = true
        }
        // Accessibility granted (owners and identities readable), scan OK, not editing; `observe` re-triggers a
        // decision when any of these change.
        guard scanner.status == .ok, !sections.isEditing, !presence.isAway,
              let controls = sections.controlWindows else { return }
        // Identity migration runs here on every backend: it moves remembered sections written under an earlier key
        // format (`IdentityMigration`) to the items' current identities, and on macOS 27 that memory is the only
        // thing the sections are read from — skipping it would show a user's arranged icons as Visible after an
        // upgrade. The window-list placement and section keeping below are macOS 26 only; 27 checks relaunched and new
        // icons in a revealed bar (`keepArrangedSections`).
        let layout = SectionAssigner.layout(of: scanner.items, controls: controls)
        guard !layout.isEmpty else { return }
        store.migrateIdentities(scanner.items)
        guard canMoveItems else {
            store.seedArrangedBaseline(scanner.items)
            if !store.keeper.pendingReturns.isEmpty {
                guard !mover.isBusy, !UserMouseButtons.isAnyHeld, !isPaused(), !ItemClicker.isMenuOnScreen() else {
                    schedule(after: Self.retryDelay)
                    return
                }
                await Task { @MainActor in await self.recoverAccessibilityReturns(controls: controls) }.value
            }
            await keepArrangedSections()
            return
        }
        guard !mover.isBusy, !UserMouseButtons.isAnyHeld, !isPaused() else {
            // Not a good time to look or move (another move transaction running, mouse held down, the Frost Bar open):
            // check again later.
            schedule(after: Self.retryDelay)
            return
        }
        let collapsed = sections.state == .collapsed
        var placements: [Placement] = []

        // New icons: only collapsed (on a crowded notched display while expanded, items that don't fit get placed left
        // of AH).
        if collapsed {
            let decision = store.decideNewItems(layout: layout, items: scanner.items, considered: considered)
            considered = decision.considered
            placements += decision.toMove.map { Placement(item: $0, section: .hidden, kind: .new) }
        }

        placements += observeSections(layout: layout, controls: controls, collapsed: collapsed,
                                      skipping: Set(placements.map(\.item.windowID)))
        guard !placements.isEmpty else { return }
        // Move in a task that doesn't inherit cancellation: the rescans during the move change `scanner.items`,
        // which triggers `observe` -> `schedule` and cancels `evaluateTask`. If the move were cancelled with it, these
        // items would be marked as seen and stay in Always Hidden forever.
        // Decisions triggered during the move retry later because of `mover.isBusy`.
        let batch = Array(placements.prefix(Self.maxMovesPerBatch))
        await Task { @MainActor in await self.move(batch, controls: controls) }.value
        if placements.count > batch.count, !mover.isShuttingDown { schedule(after: Self.retryDelay) }
    }

    /// Feeds a trustworthy layout to the `SectionKeeper` (records the user's moves, seeds unknown icons) and returns
    /// the icons to move back into their remembered sections.
    private func observeSections(layout: MenuBarLayout, controls: FrostControlWindows, collapsed: Bool,
                                 skipping: Set<CGWindowID>) -> [Placement] {
        let items = scanner.items
        let displayBounds = scanner.menuBarDisplay?.frame ?? CGDisplayBounds(CGMainDisplayID())
        // A separator under the notch (squeezed there while expanded) makes every section boundary unreliable.
        let separatorsTrusted = [controls.hiddenSeparator, controls.alwaysHiddenSeparator].allSatisfy { id in
            items.first { $0.windowID == id }
                .map { SectionKeeper.separatorIsReliable($0, displayBounds: displayBounds) } ?? false
        }
        guard separatorsTrusted else { return [] }
        let obscured = Set(items.filter { ItemMover.isObscured($0, displayBounds: displayBounds) }.map(\.windowID))
        let outcome = store.observeSections(layout: layout, items: items, obscured: obscured,
                                            movedByFrost: mover.takeMovedWindowIDs(), skipping: skipping,
                                            restoreEnabled: preferences.keepItemSections,
                                            canMove: collapsed && !mover.isShuttingDown)
        for move in outcome.userMoves {
            FrostLog.newItems.notice("""
                remembering \(move.identity.bundleID, privacy: .public) \
                (\(move.identity.key, privacy: .private)) in \(move.to.rawValue, privacy: .public): \
                moved by the user from \(move.from.rawValue, privacy: .public)
                """)
        }
        if !outcome.seeded.isEmpty {
            FrostLog.newItems.notice("remembering the sections of \(outcome.seeded.count) item(s) seen for the first time")
        }
        for identity in outcome.ambiguous.subtracting(loggedAmbiguous) {
            FrostLog.newItems.notice("""
                several items of \(identity.bundleID, privacy: .public) share the identity \
                \(identity.key, privacy: .private): not keeping their sections
                """)
        }
        loggedAmbiguous = outcome.ambiguous
        return outcome.restores.map { Placement(item: $0.item, section: $0.to, kind: .restore, restore: $0) }
    }

    /// Frost is about to move `item` out of its slot in `layout` (collapsed) temporarily (the background capture of
    /// items behind the notch): records that it must go back there, so that if Frost quits before it can, the next
    /// launch moves it back into that slot (`SectionKeeper.pendingReturns`). Returns the identity recorded (nil:
    /// unresolved or shared, nothing recorded).
    @discardableResult
    func notePendingReturn(of item: MenuBarItem, in layout: MenuBarLayout) -> ItemIdentity? {
        store.notePendingReturn(of: item, in: layout, among: scanner.items)
    }

    /// The item recorded by `notePendingReturn` is back (or gone).
    func clearPendingReturn(_ identity: ItemIdentity?) {
        if !canMoveItems, let identity { store.completeVerifiedReturn(identity) }
        else { store.clearPendingReturn(identity) }
    }

    /// Recover only Frost's own interrupted forwards on 27; ordinary section keeping remains 26-only.
    private func recoverAccessibilityReturns(controls: FrostControlWindows) async {
        do {
            try await mover.transaction {
                await sections.revealingForMove {
                    for (identity, pending) in store.keeper.pendingReturns {
                        await scanner.refreshOwnership()
                        let matches = scanner.items.filter { $0.identity == identity }
                        guard matches.count == 1, let item = matches.first, item.isMovable else { continue }
                        @MainActor func currentLayout() -> MenuBarLayout {
                            let own = Set(sections.ownItems().map { AXMenuBarInventory.ownWindowID(autosaveName: $0.autosaveName) })
                            return ArrangedLayout.layout(of: scanner.items, own: own,
                                                         remembered: { self.rememberedSection(of: $0) })
                        }
                        let plan = pending.restorePlan(for: item.windowID, in: currentLayout(), controls: controls)
                        do {
                            try await mover.move(item.windowID, to: plan.destination(in: currentLayout()), yieldingToMenus: true)
                            await scanner.refreshOwnership()
                            if plan.isInPlace(in: currentLayout()) { store.completeVerifiedReturn(identity) }
                        } catch {
                            FrostLog.newItems.error("pending AX return retained: \(error, privacy: .public)")
                        }
                    }
                }
            }
        } catch {
            FrostLog.newItems.error("pending AX recovery deferred: \(error, privacy: .public)")
        }
    }

    // MARK: - Keeping relaunched icons in their arranged sections (macOS 27)

    /// Icons already checked against their arranged section during this run (`ArrangedSectionKeeper`): each window
    /// once, when it first appears. Never pruned: an icon that disappears and comes back with the same window (an app
    /// hiding and showing it) is not checked again, so it never costs a reveal per blink; a relaunch is a new window.
    private var arrangedChecked: Set<CGWindowID> = []
    /// The icons waiting for a check and since when that set is unchanged: a burst of launches (login) is checked
    /// with one reveal once it has settled (`arrangedSettle`).
    private var arrangedCandidates: Set<CGWindowID> = []
    private var arrangedCandidatesSince: ContinuousClock.Instant = .now
    private static let arrangedSettle: Duration = .milliseconds(1500)

    /// macOS 27: when icons the user arranged appear (an app relaunched, or Frost itself launched), reveals the bar
    /// once, reads which band each one is in and moves the ones the system put elsewhere back
    /// (`restoreRelaunchedItemsWhileRevealed`). Reveals only when a remembered icon needs checking, and only when
    /// nobody is using the menu bar: collapsed, the Frost Bar closed, no menu open, no mouse button held, no other
    /// move, the user present, and Frost's own items placed this launch.
    private func keepArrangedSections() async {
        let own = sections.accessibilityDividers?.all ?? []
        let triage = ArrangedSectionKeeper.triage(items: scanner.items, own: own, checked: arrangedChecked,
                                                  skipping: Set(store.keeper.pendingReturns.keys),
                                                  remembered: { self.rememberedSectionToKeep(of: $0) },
                                                  isNew: { self.isNewIcon($0) })
        arrangedChecked.formUnion(triage.settled)
        guard !triage.candidates.isEmpty else { return }
        let ids = Set(triage.candidates.map(\.windowID))
        if ids != arrangedCandidates {
            arrangedCandidates = ids
            arrangedCandidatesSince = .now
        }
        let waited = ContinuousClock.now - arrangedCandidatesSince
        if waited < Self.arrangedSettle {
            schedule(after: Self.arrangedSettle - waited)
            return
        }
        guard sections.hasPlacedOwnItems, sections.state == .collapsed, !mover.isBusy, !mover.isShuttingDown,
              !UserMouseButtons.isAnyHeld, !isPaused(), !presence.isAway, !ItemClicker.isMenuOnScreen() else {
            schedule(after: Self.retryDelay)
            return
        }
        let newCount = triage.candidates.filter { self.isNewIcon($0) }.count
        FrostLog.newItems.notice("""
            checking \(ids.count, privacy: .public) item(s) that appeared (\(newCount, privacy: .public) new), in a \
            revealed menu bar
            """)
        // Not inheriting cancellation, like the macOS 26 moves (`evaluate`): the rescans during the reveal re-trigger
        // `observe`, which cancels the evaluation task.
        await Task { @MainActor in
            do {
                try await self.mover.transaction {
                    await self.sections.revealingForMove {
                        await self.restoreRelaunchedItems(givingUpIfUnreadable: true)
                    }
                }
            } catch {
                FrostLog.newItems.notice("arranged items not checked yet (\(error, privacy: .public)); trying again later")
            }
        }.value
        // A batch cut short (a mouse button, the Frost Bar opening, another move) leaves icons unchecked.
        let left = ArrangedSectionKeeper.triage(items: scanner.items, own: own, checked: arrangedChecked,
                                                skipping: Set(store.keeper.pendingReturns.keys),
                                                remembered: { self.rememberedSectionToKeep(of: $0) },
                                                isNew: { self.isNewIcon($0) })
        if !left.candidates.isEmpty, !mover.isShuttingDown { schedule(after: Self.retryDelay) }
    }

    /// Moves icons the system re-added outside the section the user arranged them in back into it
    /// (`ArrangedSectionKeeper`). Must run with every icon drawn (`SectionController.revealingForMove`); opens its own
    /// move transaction, and does nothing when one is running, the setting is off, or on macOS 26. Called by
    /// `SectionController.alignAccessibilityBoundaries` before it aligns the dividers (Frost's launch, and with the
    /// layout editor closed).
    func restoreRelaunchedItemsWhileRevealed() async {
        guard !canMoveItems, permissions.canManageItems, !isPaused(), !presence.isAway else { return }
        do {
            try await mover.transaction { await restoreRelaunchedItems(givingUpIfUnreadable: false) }
        } catch {
            FrostLog.newItems.notice("arranged items not checked while aligning (\(error, privacy: .public))")
        }
    }

    /// The moves themselves; inside a move transaction, with the bar revealed.
    ///
    /// `givingUpIfUnreadable`: when the bands can't be read (Frost's own items out of order), mark the icons waiting
    /// for a check as checked, so a bar Frost can't read never costs a reveal every few seconds. Not while aligning:
    /// the alignment that follows is what puts the dividers back in order, and the next check can then succeed.
    private func restoreRelaunchedItems(givingUpIfUnreadable: Bool) async {
        guard let dividers = sections.accessibilityDividers else { return }
        await scanner.refreshOwnership()
        let skipping = Set(store.keeper.pendingReturns.keys)
        guard let decision = ArrangedSectionKeeper.decide(items: scanner.items, dividers: dividers,
                                                          checked: arrangedChecked, skipping: skipping,
                                                          remembered: { self.rememberedSectionToKeep(of: $0) },
                                                          isNew: { self.isNewIcon($0) })
        else {
            FrostLog.newItems.notice("""
                not checking arranged items: Frost's dividers are not in their usual order in the revealed menu bar
                """)
            if givingUpIfUnreadable {
                let triage = ArrangedSectionKeeper.triage(items: scanner.items, own: dividers.all,
                                                          checked: arrangedChecked, skipping: skipping,
                                                          remembered: { self.rememberedSectionToKeep(of: $0) },
                                                          isNew: { self.isNewIcon($0) })
                arrangedChecked.formUnion(triage.candidates.map(\.windowID))
            }
            return
        }
        arrangedChecked.formUnion(decision.settled)
        // New icons the bar already has in Hidden or Visible: remembered there now (the others once moved).
        let moving = Set(decision.restores.map(\.item.windowID))
        for new in decision.newItems where !moving.contains(new.item.windowID) {
            recordNewIcon(new.item, in: new.section, reason: "the bar has it there")
        }
        var remaining = Set(decision.restores.map(\.item.windowID))
        for restore in decision.restores {
            let item = restore.item
            if let reason = Self.stopReason(isShuttingDown: mover.isShuttingDown,
                                            isMouseButtonPressed: UserMouseButtons.isAnyHeld,
                                            isPaused: isPaused(), isAway: presence.isAway) {
                FrostLog.newItems.notice("stopped moving arranged items back (\(reason, privacy: .public)); the rest are retried later")
                break
            }
            remaining.remove(item.windowID)
            // Checked whether or not the move works: a failed one is not retried (never fight the bar).
            arrangedChecked.insert(item.windowID)
            // Earlier moves of this batch changed the bar: read the bands again before choosing the anchor.
            await scanner.refreshOwnership()
            guard let bands = ArrangedSectionKeeper.physicalSections(of: scanner.items, dividers: dividers) else {
                FrostLog.newItems.notice("Frost's dividers moved out of order; not moving the remaining arranged items")
                break
            }
            if bands[item.windowID] == restore.to {
                if restore.isNew { recordNewIcon(item, in: restore.to, reason: "the bar has it there") }
                continue
            }
            let destination = ArrangedSectionKeeper.destination(for: restore.to, items: scanner.items, bands: bands,
                                                                dividers: dividers, excluding: remaining)
            do {
                try await mover.move(item.windowID, to: destination, yieldingToMenus: true)
                if restore.isNew {
                    recordNewIcon(item, in: restore.to, reason: """
                        moved out of \(restore.from?.rawValue ?? "between a divider and its pair") \
                        (\(String(describing: destination)))
                        """)
                    continue
                }
                FrostLog.newItems.notice("""
                    moved \(item.bundleID ?? "?", privacy: .public) (\(item.identityKey ?? "?", privacy: .private)) \
                    back to \(restore.to.rawValue, privacy: .public) \
                    (\(String(describing: destination), privacy: .public)): its app re-added it \
                    \(restore.from?.rawValue ?? "between a divider and its pair", privacy: .public)
                    """)
            } catch ItemMoveError.mouseButtonHeld {
                // Nothing was posted: retry this one later.
                arrangedChecked.remove(item.windowID)
                FrostLog.newItems.notice("stopped moving arranged items back (a mouse button is held); retried later")
                break
            } catch is CancellationError {
                arrangedChecked.remove(item.windowID)
                break
            } catch {
                FrostLog.newItems.error("""
                    failed to move \(item.bundleID ?? "?", privacy: .public) back to \
                    \(restore.to.rawValue, privacy: .public): \(error, privacy: .public)
                    """)
                // A new icon is remembered where it stayed, so the Frost Bar and the layout editor list it there.
                if restore.isNew, let from = restore.from {
                    recordNewIcon(item, in: from, reason: "moving it to \(restore.to.rawValue) failed")
                }
            }
        }
    }

    /// The section an icon goes back to when its app re-adds it elsewhere: the remembered one while "Keep icons in
    /// their sections" is on, none otherwise (accepted where it is, as on macOS 26, `SectionKeeper.observe`).
    private func rememberedSectionToKeep(of item: MenuBarItem) -> MenuBarSection? {
        preferences.keepItemSections ? rememberedSection(of: item) : nil
    }

    /// macOS 27: a new app's icon (`ItemMemoryStore.isNewOnArrangedBar`), which gets a section whatever the setting:
    /// new-icon placement isn't optional on macOS 26 either.
    private func isNewIcon(_ item: MenuBarItem) -> Bool {
        store.isNewOnArrangedBar(item, among: scanner.items)
    }

    private func recordNewIcon(_ item: MenuBarItem, in section: MenuBarSection, reason: String) {
        guard store.recordArranged(item, in: section, among: scanner.items) else { return }
        FrostLog.newItems.notice("""
            new item \(item.bundleID ?? "?", privacy: .public) (\(item.identityKey ?? "?", privacy: .private)) \
            goes in \(section.rawValue, privacy: .public): \(reason, privacy: .public)
            """)
    }

    /// The section the user keeps `item` in, as remembered from an earlier drop (`ItemMemoryStore`); nil when
    /// Frost has never been told. This is the only source of the sections on macOS 27, where the bar itself doesn't
    /// report which icons it draws.
    func rememberedSection(of item: MenuBarItem) -> MenuBarSection? {
        guard let identity = item.identity else { return nil }
        return store.keeper.memory[identity]
    }

    /// Whether anything has been arranged yet (`rememberedSection` returns nil for everything until the user drags
    /// an icon, or a macOS 26 run recorded sections).
    var hasRememberedSections: Bool { !store.keeper.memory.isEmpty }

    /// The user dropped `item` into `section` in the layout editor and the move succeeded: remember it.
    func recordDrop(_ item: MenuBarItem, in section: MenuBarSection) {
        guard store.record(item, in: section, among: scanner.items) else {
            FrostLog.newItems.notice("""
                not remembering the section of dropped item \(item.windowID): \
                its identity is unknown or shared with another item
                """)
            return
        }
        FrostLog.newItems.notice("""
            remembering \(item.bundleID ?? "?", privacy: .public) (\(item.identityKey ?? "?", privacy: .private)) \
            in \(section.rawValue, privacy: .public): dropped in the layout editor
            """)
    }

    private func move(_ placements: [Placement], controls: FrostControlWindows) async {
        // Placements a move was attempted for (moved or failed): only these are marked as seen / checked. The rest of
        // the batch is decided again later.
        var attempted: [Placement] = []
        var moved: [Placement] = []
        do {
            try await mover.transaction {
                for placement in placements {
                    let item = placement.item
                    // Re-checked before every item: a batch takes about a second per item, and a ⌘-drag must never
                    // start while the user holds a mouse button.
                    if let reason = Self.stopReason(isShuttingDown: mover.isShuttingDown,
                                                    isMouseButtonPressed: UserMouseButtons.isAnyHeld,
                                                    isPaused: isPaused(), isAway: presence.isAway) {
                        FrostLog.newItems.notice("stopped placing items (\(reason, privacy: .public)); the rest are retried later")
                        break
                    }
                    attempted.append(placement)
                    do {
                        let destination = placement.destination(
                            in: SectionAssigner.layout(of: scanner.items, controls: controls), controls: controls)
                        try await mover.move(item.windowID, to: destination)
                        moved.append(placement)
                        switch placement.kind {
                        case .new:
                            FrostLog.newItems.notice("moved new item \(item.bundleID ?? "?", privacy: .public) out of Always Hidden")
                        case .restore where placement.restore?.slot != nil:
                            FrostLog.newItems.notice("""
                                moved \(item.bundleID ?? "?", privacy: .public) (\(item.identityKey ?? "?", privacy: .private)) \
                                back to \(placement.section.rawValue, privacy: .public) \
                                (\(String(describing: destination), privacy: .public)): Frost had moved it out before quitting
                                """)
                        case .restore:
                            FrostLog.newItems.notice("""
                                moved \(item.bundleID ?? "?", privacy: .public) (\(item.identityKey ?? "?", privacy: .private)) \
                                back to \(placement.section.rawValue, privacy: .public): its app re-added it elsewhere
                                """)
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch ItemMoveError.mouseButtonHeld {
                        // The user held a mouse button throughout: nothing was posted; retry this one later too.
                        attempted.removeLast()
                        FrostLog.newItems.notice("stopped placing items (a mouse button is held); the rest are retried later")
                        break
                    } catch ItemMoveError.controlsDisturbed {
                        // Frost's own icons were dragged (routing fell back to position): stop moving the rest.
                        FrostLog.newItems.error("stopped placing items: Frost's controls were disturbed")
                        break
                    } catch {
                        FrostLog.newItems.error("""
                            failed to move \(item.bundleID ?? "?", privacy: .public) to \
                            \(placement.section.rawValue, privacy: .public): \(error, privacy: .public)
                            """)
                    }
                }
            }
        } catch ItemMoveError.shuttingDown {
            // Frost is quitting: these items aren't marked as seen and are placed on the next launch.
            return
        } catch ItemMoveError.busy {
            // Another transaction just started: retry later (these items aren't marked as seen yet).
            schedule(after: Self.retryDelay)
            return
        } catch is CancellationError {
            // Shouldn't happen (see `evaluate`); if cancelled anyway, don't mark as seen and retry later.
            schedule(after: Self.retryDelay)
            return
        } catch {
            FrostLog.newItems.error("placing items failed: \(error, privacy: .public)")
        }
        let newItems = attempted.filter { $0.kind == .new }.map(\.item)
        considered.formUnion(newItems.map(\.windowID))
        store.remember(Set(newItems.compactMap(NewItemPlacement.identity(of:))), seeding: false)
        store.restoresAttempted(attempted.filter { $0.kind == .restore }.map(\.item))
        // A new icon Frost placed in Hidden belongs there until the user moves it.
        store.recordPlaced(moved.filter { $0.kind == .new }.map { (item: $0.item, section: $0.section) },
                           among: scanner.items)
        if attempted.count < placements.count, !mover.isShuttingDown { schedule(after: Self.retryDelay) }
    }

    /// Why the rest of a batch must wait (nil = go on with the next item).
    private static func stopReason(isShuttingDown: Bool, isMouseButtonPressed: Bool, isPaused: Bool,
                                   isAway: Bool) -> String? {
        if isShuttingDown { return "Frost is quitting" }
        if isMouseButtonPressed { return "a mouse button is held" }
        if isPaused { return "the Frost Bar is open or forwarding a click" }
        if isAway { return "the user is away" }
        return nil
    }
}
