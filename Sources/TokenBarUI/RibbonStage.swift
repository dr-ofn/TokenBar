import CoreGraphics
import LocalCore
import Observation

/// What the pointer is on and what was clicked; the panel and the dashboard each keep one.
@Observable
public final class RibbonStage {
    public var selected: UsageSelection?
    public var hovered: UsageSelection?
    /// The token kind under the pointer, when the ribbon there shows its kinds.
    public var hoveredKind: TokenKind?
    /// Read only by the note beside the pointer, so moving it repaints only that note.
    public var pointer: CGPoint?
    public var expanded: HarnessID?
    /// The list of detected tools is open where the breakdown would be.
    public var showsDetected = false

    public init() {}

    public var focus: UsageSelection? { hovered ?? selected }

    public func toggle(_ selection: UsageSelection) {
        selected = selected == selection ? nil : selection
        if selected != nil { showsDetected = false }
    }

    /// Opens or closes the detected tools; opening drops the breakdown, which would sit in the same place.
    public func toggleDetected() {
        showsDetected.toggle()
        if showsDetected { selected = nil }
    }

    /// A breakdown or the detected tools are open.
    public var hasOpenPanel: Bool { selected != nil || showsDetected }

    public func closePanel() {
        selected = nil
        showsDetected = false
    }

    public func toggleExpanded(_ harness: HarnessID) {
        expanded = expanded == harness ? nil : harness
    }

    /// A click can move the picture out from under a still pointer, so it clears these too.
    public func clearHover() {
        hovered = nil
        hoveredKind = nil
        pointer = nil
    }
}
