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

    @Test func macOS27DeliversOptionClicksAsPlainClicks() {
        // The bar redelivers a click to its app without its modifier flags (measured), so an Option click can only
        // arrive as a plain one; buttons survive.
        #expect(ForwardedClick.primaryWithOption.deliverable(on: .accessibility) == .primary)
        #expect(ForwardedClick.secondary.deliverable(on: .accessibility) == .secondary)
        #expect(ForwardedClick.primary.deliverable(on: .accessibility) == .primary)
        // macOS 26 delivers every kind as is.
        #expect(ForwardedClick.primaryWithOption.deliverable(on: .windowList) == .primaryWithOption)
        #expect(ForwardedClick.secondary.deliverable(on: .windowList) == .secondary)
    }
}
