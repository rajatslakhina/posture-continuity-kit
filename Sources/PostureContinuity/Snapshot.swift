import Foundation

// MARK: - Identity

/// A flow is a unit of in-flight user work: a checkout, a search session, a
/// message composer. It is the thing that must survive a fold, so it is the
/// unit the coordinator tracks.
public struct FlowID: Sendable, Hashable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

// MARK: - Width-independent scroll position

/// A pixel offset does not survive a width change: the same 1,240 pt down
/// means a different row once every row reflows. An anchor names the item at
/// the top of the viewport and how far into it the viewport starts, which is
/// meaningful in any width. This is the single most common continuity bug
/// on resizable devices and the reason this type exists.
public struct ScrollAnchor: Sendable, Hashable, Codable {
    public var itemID: String
    /// How far into `itemID` the viewport's leading edge sits, `0...1`.
    public var offsetWithinItem: Double

    public init(itemID: String, offsetWithinItem: Double = 0) {
        self.itemID = itemID
        self.offsetWithinItem = Sanitize.unitFraction(offsetWithinItem)
    }

    /// Builds an anchor from a raw pixel offset and a list of item heights,
    /// which is what a legacy scroll view gives you. Never traps: an empty
    /// list, zero heights, negative or non-finite offsets all resolve to a
    /// well-formed anchor or `nil`.
    public static func fromPixelOffset(
        _ offset: Double,
        itemIDs: [String],
        itemHeights: [Double]
    ) -> ScrollAnchor? {
        guard !itemIDs.isEmpty, itemIDs.count == itemHeights.count else { return nil }
        let target = Sanitize.nonNegativeFinite(offset)
        var cursor: Double = 0
        for index in itemIDs.indices {
            let height = Sanitize.nonNegativeFinite(itemHeights[index])
            let next = cursor + height
            if target < next || index == itemIDs.count - 1 {
                let within = height > 0 ? (target - cursor) / height : 0
                return ScrollAnchor(itemID: itemIDs[index], offsetWithinItem: within)
            }
            cursor = next
        }
        return nil
    }

    /// Re-projects the anchor into a new layout's item heights. If the anchor
    /// item no longer exists (filtered out, deleted), returns `nil` so the
    /// caller can fall back rather than jump to row zero silently.
    public func pixelOffset(itemIDs: [String], itemHeights: [Double]) -> Double? {
        guard itemIDs.count == itemHeights.count,
              let index = itemIDs.firstIndex(of: itemID) else { return nil }
        var offset: Double = 0
        for i in itemIDs.indices where i < index {
            offset += Sanitize.nonNegativeFinite(itemHeights[i])
        }
        let height = Sanitize.nonNegativeFinite(itemHeights[index])
        return offset + height * offsetWithinItem
    }
}

// MARK: - Navigation, focus, presentation

public enum NavigationRoute: Sendable, Hashable, Codable {
    case list
    case detail(String)
    case editor(String)
}

/// Navigation state has two shapes. In one column it is a stack; in two
/// columns the list lives in the sidebar and the first detail is a selection.
/// Both are kept so projection between them is lossless in either direction.
public struct NavigationState: Sendable, Hashable, Codable {
    public var stack: [NavigationRoute]
    public var selection: String?

    public init(stack: [NavigationRoute] = [], selection: String? = nil) {
        self.stack = stack
        self.selection = selection
    }
}

public struct FocusTarget: Sendable, Hashable, Codable {
    public var fieldID: String
    /// Caret position; clamped by the consumer against the live text length,
    /// never trusted blindly.
    public var caret: Int?

    public init(fieldID: String, caret: Int? = nil) {
        self.fieldID = fieldID
        self.caret = caret.map { max(0, $0) }
    }
}

/// Everything a flow needs to put itself back exactly where the user left it.
/// Deliberately all value types, all `Codable`: a snapshot can be journaled,
/// persisted across a scene disconnect, or replayed in a test.
public struct ContinuitySnapshot: Sendable, Hashable, Codable {
    public var flow: FlowID
    public var scroll: ScrollAnchor?
    public var focus: FocusTarget?
    public var navigation: NavigationState
    /// Presented sheet identifiers, bottom to top.
    public var sheets: [String]
    /// Unsubmitted form contents, keyed by field.
    public var draft: [String: String]

    public init(
        flow: FlowID,
        scroll: ScrollAnchor? = nil,
        focus: FocusTarget? = nil,
        navigation: NavigationState = NavigationState(),
        sheets: [String] = [],
        draft: [String: String] = [:]
    ) {
        self.flow = flow
        self.scroll = scroll
        self.focus = focus
        self.navigation = navigation
        self.sheets = sheets
        self.draft = draft
    }
}

// MARK: - Flow descriptor

/// What the coordinator needs to know about a flow to project its state into
/// a different layout: which fields exist in each mode. A field that only
/// exists in the two-column editor pane cannot keep focus after a fold.
public struct FlowDescriptor: Sendable, Hashable {
    public var id: FlowID
    public var fieldsBySingleColumn: Set<String>
    public var fieldsByTwoColumn: Set<String>

    public init(id: FlowID, fieldsBySingleColumn: Set<String>, fieldsByTwoColumn: Set<String>) {
        self.id = id
        self.fieldsBySingleColumn = fieldsBySingleColumn
        self.fieldsByTwoColumn = fieldsByTwoColumn
    }

    /// A flow whose fields are the same everywhere — the common case.
    public init(id: FlowID, fields: Set<String>) {
        self.init(id: id, fieldsBySingleColumn: fields, fieldsByTwoColumn: fields)
    }

    public func fields(in mode: LayoutMode) -> Set<String> {
        switch mode {
        case .singleColumn: return fieldsBySingleColumn
        case .twoColumn: return fieldsByTwoColumn
        }
    }
}

// MARK: - Projection

/// Why a restored snapshot is not exactly the captured one. Every case is
/// something the product team should be able to count in the field.
public enum Degradation: Sendable, Hashable, Codable {
    /// The flow never answered the capture request; its last settled
    /// checkpoint was used instead.
    case captureMissed
    /// The posture changed with no transitioning observation first, so there
    /// was no window in which to ask for a capture.
    case noCaptureWindow
    /// The focused field does not exist in the target layout.
    case focusDropped(field: String)
    /// The flow had neither a capture nor a checkpoint; restored to empty.
    case noStateOfRecord
}

/// Pure functions that move a snapshot between layout modes. Nothing here
/// touches the coordinator, so every rule is unit-testable in isolation.
public enum SnapshotProjector {
    public struct Result: Sendable, Hashable {
        public var snapshot: ContinuitySnapshot
        public var degradations: [Degradation]
    }

    public static func project(
        _ snapshot: ContinuitySnapshot,
        from source: LayoutMode,
        to target: LayoutMode,
        descriptor: FlowDescriptor?
    ) -> Result {
        var projected = snapshot
        var degradations: [Degradation] = []

        projected.navigation = projectNavigation(snapshot.navigation, from: source, to: target)

        if let focus = snapshot.focus, let descriptor {
            if !descriptor.fields(in: target).contains(focus.fieldID) {
                projected.focus = nil
                degradations.append(.focusDropped(field: focus.fieldID))
            }
        }

        return Result(snapshot: projected, degradations: degradations)
    }

    /// Stack ⇄ split conversion. Idempotent when source and target agree.
    public static func projectNavigation(
        _ navigation: NavigationState,
        from source: LayoutMode,
        to target: LayoutMode
    ) -> NavigationState {
        switch (source.isTwoColumn, target.isTwoColumn) {
        case (false, true):
            // Stack → split. `.list` becomes the sidebar; the first detail
            // becomes the selection; anything pushed above it stays pushed.
            var stack = navigation.stack
            if stack.first == .list { stack.removeFirst() }
            var selection = navigation.selection
            if selection == nil, let first = stack.first, case .detail(let id) = first {
                selection = id
                stack.removeFirst()
            }
            return NavigationState(stack: stack, selection: selection)
        case (true, false):
            // Split → stack. Selection is re-materialised as a pushed detail
            // on top of the list so the user can pop back to it. A stack that
            // already begins with `.list` and has no selection is already in
            // stack shape; leave it alone rather than pushing a second list.
            if navigation.selection == nil, navigation.stack.first == .list { return navigation }
            var stack: [NavigationRoute] = [.list]
            if let selection = navigation.selection { stack.append(.detail(selection)) }
            stack.append(contentsOf: navigation.stack)
            return NavigationState(stack: stack, selection: nil)
        case (true, true), (false, false):
            return navigation
        }
    }
}
