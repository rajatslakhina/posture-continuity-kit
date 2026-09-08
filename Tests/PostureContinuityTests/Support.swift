import XCTest
@testable import PostureContinuity

enum Fixtures {
    static let checkout = FlowID("checkout")
    static let search = FlowID("search")

    static let compact = DisplayPosture(
        layoutClass: .compact, phase: .settled, size: Extent(width: 390, height: 844), hinge: nil)
    static let expanded = DisplayPosture(
        layoutClass: .expanded, phase: .settled, size: Extent(width: 760, height: 844), hinge: nil)
    static let moving = DisplayPosture(
        layoutClass: .compact, phase: .transitioning, size: Extent(width: 560, height: 844),
        hinge: HingeGeometry(axis: .horizontal, separatorFraction: 0.5, angleDegrees: 90))

    /// Checkout has an editor-only field in two-column mode, so a fold can
    /// legitimately drop focus. Search has the same fields everywhere.
    static let checkoutDescriptor = FlowDescriptor(
        id: checkout,
        fieldsBySingleColumn: ["email", "address"],
        fieldsByTwoColumn: ["email", "address", "promo-code"])
    static let searchDescriptor = FlowDescriptor(id: search, fields: ["query"])

    static func checkoutSnapshot(focus: String? = "email") -> ContinuitySnapshot {
        ContinuitySnapshot(
            flow: checkout,
            scroll: ScrollAnchor(itemID: "item-7", offsetWithinItem: 0.25),
            focus: focus.map { FocusTarget(fieldID: $0, caret: 3) },
            navigation: NavigationState(stack: [.list, .detail("order-1")]),
            sheets: ["address-picker"],
            draft: ["email": "r@example.com"])
    }

    static func coordinator(
        registry: LayoutPolicyRegistry = LayoutPolicyRegistry(),
        registerFlows: Bool = true
    ) async -> ContinuityCoordinator {
        let coordinator = ContinuityCoordinator(
            configuration: .init(registry: registry))
        if registerFlows {
            await coordinator.register(checkoutDescriptor)
            await coordinator.register(searchDescriptor)
        }
        return coordinator
    }
}

extension SettleOutcome {
    var bundle: RestoreBundle? {
        switch self {
        case .settled(let bundle), .implicit(let bundle): return bundle
        case .reverted, .unchanged: return nil
        }
    }
}

extension IngestOutcome {
    var settleOutcome: SettleOutcome? {
        if case .settle(let outcome) = self { return outcome }
        return nil
    }

    var ticket: TransitionTicket? {
        if case .transitionOpened(let ticket) = self { return ticket }
        return nil
    }
}
