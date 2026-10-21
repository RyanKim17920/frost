import CoreGraphics

/// Which click the Frost Bar forwards to a hidden item, chosen from the click on its tile.
///
/// - Plain left click: a plain left click (AXPress first, see `ItemClicker.click`).
/// - Right click, or Control + left click: a right click (HID `rightMouseDown` / `rightMouseUp`). Many status items
///   show a different (secondary) menu on a right click, chosen by the current event's type; AXPress / AXShowMenu
///   deliver no mouse event, so only a real right click reliably reaches that menu.
/// - Option + left click: a left click with the Option modifier (HID event; AXPress carries no modifiers). Some apps
///   show extra entries in their menu.
public enum ForwardedClick: Equatable, Sendable {
    case primary
    case secondary
    case primaryWithOption

    public enum Button: Equatable, Sendable { case left, right, other }

    /// Maps the click on a tile to the click to forward; nil for buttons that don't forward (e.g. the middle button).
    /// Control wins over Option (Control + left click is the classic right click).
    public static func kind(button: Button, control: Bool, option: Bool) -> ForwardedClick? {
        switch button {
        case .right: .secondary
        case .left where control: .secondary
        case .left where option: .primaryWithOption
        case .left: .primary
        case .other: nil
        }
    }

    /// Whether the click must be a HID event (AXPress can only do a plain primary click).
    public var requiresEvent: Bool { self != .primary }

    /// The mouse button of the forwarded events.
    public var mouseButton: CGMouseButton { self == .secondary ? .right : .left }

    /// The down / up event types of the forwarded click.
    public var eventTypes: (down: CGEventType, up: CGEventType) {
        self == .secondary ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
    }

    /// Modifier flags of the forwarded events.
    public var flags: CGEventFlags { self == .primaryWithOption ? .maskAlternate : [] }

    /// One event of a forwarded click, in posting order.
    public enum PlannedEvent: Equatable, Sendable {
        case mouse(CGEventType, CGMouseButton, flags: CGEventFlags)
        /// A modifier key going down or up (a `flagsChanged` event), with the flags in effect afterwards.
        case modifierKey(CGKeyCode, down: Bool, flags: CGEventFlags)
    }

    /// The virtual key code of the left Option key (`kVK_Option`).
    public static let optionKeyCode: CGKeyCode = 0x3A

    /// The events that make up this click, in posting order.
    ///
    /// Always a lone left mouse-up first (it ends the "pressed" state a ⌘-drag can leave behind; see
    /// `ItemClicker.postClick`), then the click's down / up carrying `flags`.
    ///
    /// `holdingModifierKeys` (macOS 27): the click's modifier keys are also pressed for real around the mouse events
    /// (a key-down `flagsChanged` before, the matching key-up after). There `MenuBarAgent` receives the click and
    /// redelivers it to the item's app, and the redelivered event can lose the flags it was posted with (measured on
    /// Frost's own snowflake), so an app reading the event's flags or the current modifier state
    /// (`NSEvent.modifierFlags`) only sees Option while the key is held. The key-up is part of the same sequence, so
    /// whoever posts it never leaves the key held.
    public func events(holdingModifierKeys: Bool = false) -> [PlannedEvent] {
        let (down, up) = eventTypes
        let click: [PlannedEvent] = [.mouse(down, mouseButton, flags: flags), .mouse(up, mouseButton, flags: flags)]
        let leading = PlannedEvent.mouse(.leftMouseUp, .left, flags: [])
        guard holdingModifierKeys, self == .primaryWithOption else { return [leading] + click }
        return [leading, .modifierKey(Self.optionKeyCode, down: true, flags: flags)] + click
            + [.modifierKey(Self.optionKeyCode, down: false, flags: [])]
    }

    /// Short name for logs.
    public var logName: String {
        switch self {
        case .primary: "left"
        case .secondary: "right"
        case .primaryWithOption: "option-left"
        }
    }
}
