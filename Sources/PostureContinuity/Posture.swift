import Foundation

// MARK: - Raw observation

/// What the platform hands you, before any interpretation. On iOS 27 this is
/// assembled from `UIWindowScene.effectiveGeometry`, the trait collection and
/// the fold-state / hinge-angle values the betas expose; in tests and in the
/// demo it is scripted or replayed. It is deliberately a dumb bag of numbers:
/// the *meaning* of a width or an angle is a policy decision, made once, in
/// `PostureInterpreter`, not scattered across views.
public struct PostureObservation: Sendable, Hashable, Codable {
    public var width: Double
    public var height: Double
    public var foldState: FoldState
    /// Hinge angle in degrees when the hardware reports one. May arrive as
    /// NaN, infinite or out of range from a flaky source; the interpreter
    /// sanitises it, so nothing downstream ever sees a bad value.
    public var hingeAngleDegrees: Double?
    /// Monotonic milliseconds from whatever clock the caller owns. Ordering
    /// only; never compared against wall time.
    public var timestampMillis: Int64

    public init(
        width: Double,
        height: Double,
        foldState: FoldState = .unknown,
        hingeAngleDegrees: Double? = nil,
        timestampMillis: Int64 = 0
    ) {
        self.width = width
        self.height = height
        self.foldState = foldState
        self.hingeAngleDegrees = hingeAngleDegrees
        self.timestampMillis = timestampMillis
    }
}

/// Mirrors the fold-state vocabulary that surfaced in the iOS 27 betas. The
/// raw values are the strings; the cases are what the code reasons about.
public enum FoldState: String, Sendable, Hashable, Codable, CaseIterable {
    case unknown
    case flat
    case folded
    case halfOpened
    case transitioning
}

// MARK: - Interpreted posture

/// Two classes, on purpose. Size classes have `regular` meaning "somewhere
/// between 5 and 13 inches", which is why every screen ends up special-casing
/// them. The continuity machinery only needs to know whether the feature has
/// room for a second column; finer decisions belong to `FeatureLayoutPolicy`.
public enum LayoutClass: String, Sendable, Hashable, Codable {
    case compact
    case expanded
}

public enum PosturePhase: String, Sendable, Hashable, Codable {
    /// Geometry is stable. Snapshots taken now are trustworthy.
    case settled
    /// The hinge is moving or the window is mid-resize. Geometry observed now
    /// is transient and must never be captured as state of record.
    case transitioning
}

public enum HingeAxis: String, Sendable, Hashable, Codable {
    /// The hinge runs top-to-bottom; the two panels sit side by side.
    case vertical
    /// The hinge runs left-to-right; the two panels are stacked.
    case horizontal
}

/// Hinge geometry is an *input* to layout, never a layout itself. A policy may
/// choose to split around the separator; it may equally ignore it.
public struct HingeGeometry: Sendable, Hashable, Codable {
    public var axis: HingeAxis
    /// Where the separator falls along the hinge axis, as a fraction of the
    /// extent, clamped to `0...1`.
    public var separatorFraction: Double
    /// Clamped to `0...180`; `180` is flat.
    public var angleDegrees: Double

    public init(axis: HingeAxis, separatorFraction: Double, angleDegrees: Double) {
        self.axis = axis
        self.separatorFraction = Sanitize.unitFraction(separatorFraction)
        self.angleDegrees = Sanitize.clamp(angleDegrees, lower: 0, upper: 180)
    }
}

/// Sanitised size in points. Never NaN, never negative, never infinite.
public struct Extent: Sendable, Hashable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = Sanitize.nonNegativeFinite(width)
        self.height = Sanitize.nonNegativeFinite(height)
    }
}

/// The domain model the rest of the system consumes. Value type, so a posture
/// captured in a journal entry cannot change under you.
public struct DisplayPosture: Sendable, Hashable, Codable {
    public var layoutClass: LayoutClass
    public var phase: PosturePhase
    public var size: Extent
    public var hinge: HingeGeometry?

    public init(layoutClass: LayoutClass, phase: PosturePhase, size: Extent, hinge: HingeGeometry? = nil) {
        self.layoutClass = layoutClass
        self.phase = phase
        self.size = size
        self.hinge = hinge
    }

    /// Two settled postures are "the same place" for continuity purposes when
    /// the layout class and the hinge axis agree. Width jitter of a few points
    /// is not a transition; it is a resize the layout absorbs on its own.
    public func isEquivalent(to other: DisplayPosture) -> Bool {
        layoutClass == other.layoutClass && hinge?.axis == other.hinge?.axis
    }
}

// MARK: - Interpreter

/// Turns raw observations into postures. Thresholds are injected so a team
/// owns them in one place; the defaults are the ones the demo uses.
public struct PostureInterpreter: Sendable {
    /// Width at or above which the display is `expanded`.
    public var expandedMinimumWidth: Double
    /// A hinge angle strictly inside `(foldedBelowDegrees, flatAboveDegrees)`
    /// counts as transitioning even if the fold state says otherwise — the
    /// angle stream is usually ahead of the state string. `halfOpened` is the
    /// one exception: it is a resting posture, so its angle is not read as
    /// motion.
    public var foldedBelowDegrees: Double
    public var flatAboveDegrees: Double

    public init(
        expandedMinimumWidth: Double = 600,
        foldedBelowDegrees: Double = 20,
        flatAboveDegrees: Double = 160
    ) {
        self.expandedMinimumWidth = Sanitize.nonNegativeFinite(expandedMinimumWidth)
        let folded = Sanitize.clamp(foldedBelowDegrees, lower: 0, upper: 180)
        let flat = Sanitize.clamp(flatAboveDegrees, lower: 0, upper: 180)
        // Guarantee folded <= flat so the "inside" band is well-formed even
        // when a caller swaps the two.
        self.foldedBelowDegrees = min(folded, flat)
        self.flatAboveDegrees = max(folded, flat)
    }

    public func interpret(_ observation: PostureObservation) -> DisplayPosture {
        let size = Extent(width: observation.width, height: observation.height)
        let layoutClass: LayoutClass = size.width >= expandedMinimumWidth ? .expanded : .compact

        let angle: Double? = observation.hingeAngleDegrees.flatMap { raw in
            raw.isFinite ? Sanitize.clamp(raw, lower: 0, upper: 180) : nil
        }

        let angleSaysMoving: Bool = {
            guard let angle else { return false }
            return angle > foldedBelowDegrees && angle < flatAboveDegrees
        }()

        let phase: PosturePhase
        switch observation.foldState {
        case .transitioning:
            phase = .transitioning
        case .halfOpened:
            phase = .settled
        case .flat, .folded, .unknown:
            phase = angleSaysMoving ? .transitioning : .settled
        }

        let hinge: HingeGeometry?
        switch observation.foldState {
        case .flat, .unknown:
            hinge = nil
        case .folded, .halfOpened, .transitioning:
            let axis: HingeAxis = size.width >= size.height ? .vertical : .horizontal
            hinge = HingeGeometry(axis: axis, separatorFraction: 0.5, angleDegrees: angle ?? 180)
        }

        return DisplayPosture(layoutClass: layoutClass, phase: phase, size: size, hinge: hinge)
    }
}

// MARK: - Sanitisation helpers

/// Every numeric edge that could trap or poison a layout lives here, once.
public enum Sanitize {
    public static func nonNegativeFinite(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    public static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        guard value.isFinite else { return lower }
        let lo = min(lower, upper)
        let hi = max(lower, upper)
        return min(max(value, lo), hi)
    }

    public static func unitFraction(_ value: Double) -> Double {
        clamp(value, lower: 0, upper: 1)
    }

    /// `Int(Double)` traps on NaN, infinity and out-of-range values. This
    /// never does: NaN becomes 0, ±infinity saturates like any other
    /// out-of-range value. The ceiling is derived from `Int.max` so it is
    /// correct on 32-bit `Int` as well.
    public static func saturatingInt(_ value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        // `Double(Int.max)` rounds *up* to 2^63 on 64-bit, which is itself out
        // of range for `Int(_:)`, so the usable ceiling is the next double
        // below it. `Double(Int.min)` is exact.
        let ceiling = Double(Int.max).nextDown
        let floor = Double(Int.min)
        if value >= ceiling { return Int(ceiling) }
        if value <= floor { return Int.min }
        return Int(value)
    }
}
