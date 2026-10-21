import CoreGraphics
import Testing
@testable import FrostCore

@Suite struct ForwardedClickTests {
    @Test func mapsTileClicksToForwardedClicks() {
        #expect(ForwardedClick.kind(button: .left, control: false, option: false) == .primary)
        #expect(ForwardedClick.kind(button: .right, control: false, option: false) == .secondary)
        #expect(ForwardedClick.kind(button: .right, control: false, option: true) == .secondary)
        #expect(ForwardedClick.kind(button: .left, control: true, option: false) == .secondary)
        // Control wins over Option.
        #expect(ForwardedClick.kind(button: .left, control: true, option: true) == .secondary)
        #expect(ForwardedClick.kind(button: .left, control: false, option: true) == .primaryWithOption)
        #expect(ForwardedClick.kind(button: .other, control: false, option: false) == nil)
    }

    @Test func eventsMatchTheKind() {
        #expect(!ForwardedClick.primary.requiresEvent)
        #expect(ForwardedClick.secondary.requiresEvent)
        #expect(ForwardedClick.primaryWithOption.requiresEvent)
        #expect(ForwardedClick.secondary.mouseButton == .right)
        #expect(ForwardedClick.secondary.eventTypes.down == .rightMouseDown)
        #expect(ForwardedClick.secondary.eventTypes.up == .rightMouseUp)
        #expect(ForwardedClick.secondary.flags.isEmpty)
        #expect(ForwardedClick.primaryWithOption.mouseButton == .left)
        #expect(ForwardedClick.primaryWithOption.eventTypes.down == .leftMouseDown)
        #expect(ForwardedClick.primaryWithOption.flags == .maskAlternate)
        #expect(ForwardedClick.primary.flags.isEmpty)
    }

    @Test func clicksStartWithALoneMouseUpAndCarryTheirFlags() {
        #expect(ForwardedClick.primary.events() == [
            .mouse(.leftMouseUp, .left, flags: []),
            .mouse(.leftMouseDown, .left, flags: []), .mouse(.leftMouseUp, .left, flags: []),
        ])
        #expect(ForwardedClick.secondary.events() == [
            .mouse(.leftMouseUp, .left, flags: []),
            .mouse(.rightMouseDown, .right, flags: []), .mouse(.rightMouseUp, .right, flags: []),
        ])
        // macOS 26: Option only on the mouse events, no key is pressed.
        #expect(ForwardedClick.primaryWithOption.events() == [
            .mouse(.leftMouseUp, .left, flags: []),
            .mouse(.leftMouseDown, .left, flags: .maskAlternate), .mouse(.leftMouseUp, .left, flags: .maskAlternate),
        ])
    }

    @Test func holdingModifierKeysPressesOptionAroundTheClickAndReleasesIt() {
        let events = ForwardedClick.primaryWithOption.events(holdingModifierKeys: true)
        #expect(events == [
            .mouse(.leftMouseUp, .left, flags: []),
            .modifierKey(ForwardedClick.optionKeyCode, down: true, flags: .maskAlternate),
            .mouse(.leftMouseDown, .left, flags: .maskAlternate), .mouse(.leftMouseUp, .left, flags: .maskAlternate),
            .modifierKey(ForwardedClick.optionKeyCode, down: false, flags: []),
        ])
        // Every key that goes down comes back up, last.
        #expect(events.last == .modifierKey(ForwardedClick.optionKeyCode, down: false, flags: []))
    }

    @Test func holdingModifierKeysChangesNothingWithoutModifiers() {
        #expect(ForwardedClick.primary.events(holdingModifierKeys: true) == ForwardedClick.primary.events())
        #expect(ForwardedClick.secondary.events(holdingModifierKeys: true) == ForwardedClick.secondary.events())
    }
}
