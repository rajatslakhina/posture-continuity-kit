import Foundation

// MARK: - Layout mode

/// The decision a feature actually needs. Not a size class, not a device
/// idiom: "do I have a second column, and if so how wide is the first one."
public enum LayoutMode: Sendable, Hashable, Codable {
    case singleColumn
    /// `sidebarFraction` is the leading column's share of the width, `0...1`.
    case twoColumn(sidebarFraction: Double)

    public var isTwoColumn: Bool {
        if case .twoColumn = self { return true }
        return false
    }

    /// Two-column with a sanitised fraction; never stores NaN or out-of-range.
    public static func split(_ fraction: Double) -> LayoutMode {
        .twoColumn(sidebarFraction: Sanitize.unitFraction(fraction))
    }
}

// MARK: - Policy protocol

/// Decided **per feature**, not per screen. A product list wants two columns
/// at 600 pt; a checkout form wants one column until 900 pt because a split
/// checkout is a conversion risk. One global breakpoint cannot express that;
/// a policy registered per `FlowID` can.
public protocol FeatureLayoutPolicy: Sendable {
    func resolve(_ posture: DisplayPosture) -> LayoutMode
}

/// Two columns once the width clears a threshold. The workhorse.
public struct WidthThresholdPolicy: FeatureLayoutPolicy {
    public var minimumWidthForTwoColumns: Double
    public var sidebarFraction: Double

    public init(minimumWidthForTwoColumns: Double = 600, sidebarFraction: Double = 0.38) {
        self.minimumWidthForTwoColumns = Sanitize.nonNegativeFinite(minimumWidthForTwoColumns)
        self.sidebarFraction = Sanitize.unitFraction(sidebarFraction)
    }

    public func resolve(_ posture: DisplayPosture) -> LayoutMode {
        guard posture.layoutClass == .expanded,
              posture.size.width >= minimumWidthForTwoColumns else { return .singleColumn }
        return .split(sidebarFraction)
    }
}

/// Never splits. For flows where a second column is a product decision the
/// team has explicitly declined — payment entry, a signature pad.
public struct AlwaysSingleColumnPolicy: FeatureLayoutPolicy {
    public init() {}
    public func resolve(_ posture: DisplayPosture) -> LayoutMode { .singleColumn }
}

/// Wraps another policy and, when a vertical hinge is present, moves the
/// column boundary onto the hinge so no control straddles the crease. A
/// horizontal hinge (laptop posture) forces a single column: stacking two
/// panels across a fold is the layout users photograph and post.
public struct HingeAvoidingPolicy: FeatureLayoutPolicy {
    public var base: any FeatureLayoutPolicy

    public init(base: any FeatureLayoutPolicy) {
        self.base = base
    }

    public func resolve(_ posture: DisplayPosture) -> LayoutMode {
        let baseMode = base.resolve(posture)
        guard let hinge = posture.hinge else { return baseMode }
        switch hinge.axis {
        case .horizontal:
            return .singleColumn
        case .vertical:
            guard baseMode.isTwoColumn else { return .singleColumn }
            return .split(hinge.separatorFraction)
        }
    }
}

// MARK: - Registry

/// Resolves a layout mode for a flow. Value type: the registry a coordinator
/// was created with cannot be mutated behind its back.
public struct LayoutPolicyRegistry: Sendable {
    private var policies: [FlowID: any FeatureLayoutPolicy]
    public var fallback: any FeatureLayoutPolicy

    public init(fallback: any FeatureLayoutPolicy = WidthThresholdPolicy()) {
        self.policies = [:]
        self.fallback = fallback
    }

    public mutating func register(_ policy: any FeatureLayoutPolicy, for flow: FlowID) {
        policies[flow] = policy
    }

    public func registering(_ policy: any FeatureLayoutPolicy, for flow: FlowID) -> LayoutPolicyRegistry {
        var copy = self
        copy.register(policy, for: flow)
        return copy
    }

    public func resolve(_ flow: FlowID, in posture: DisplayPosture) -> LayoutMode {
        (policies[flow] ?? fallback).resolve(posture)
    }

    public var registeredFlows: Set<FlowID> { Set(policies.keys) }
}
