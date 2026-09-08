import Foundation

// MARK: - Generation

/// Monotonic per coordinator. A generation opens when a transition begins and
/// closes when it settles; every capture and every restore carries the
/// generation it belongs to, which is what makes stale work detectable.
public struct Generation: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public static func < (lhs: Generation, rhs: Generation) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "g\(rawValue)" }

    /// Saturates instead of trapping. Reaching `UInt64.max` transitions in one
    /// process is not a realistic concern, but "cannot trap" is the bar.
    public func next() -> Generation {
        rawValue == UInt64.max ? self : Generation(rawValue + 1)
    }
}

// MARK: - Events

/// One line per thing that happened. This is the observability hook: ship it
/// to analytics as-is and you can count degraded restores, storms and stale
/// captures in the field, per flow, without instrumenting any view.
public enum PostureEvent: Sendable, Hashable, Codable {
    case baselineSettled(DisplayPosture, at: Int64)
    case transitionOpened(Generation, from: DisplayPosture, toward: DisplayPosture, at: Int64)
    /// A second `begin` while one was open. The target is updated; the
    /// snapshot of record is not, because state mid-transition is transient.
    case transitionContinued(Generation, toward: DisplayPosture, at: Int64)
    case captureAccepted(Generation, flow: FlowID)
    case captureRejected(Generation, flow: FlowID, reason: CaptureRejection)
    case checkpointAccepted(flow: FlowID)
    case checkpointRejected(flow: FlowID, reason: CheckpointRejection)
    /// The transition ended where it began — fold, unfold within the hold.
    case transitionReverted(Generation, at: Int64, storms: Int)
    case transitionSettled(Generation, posture: DisplayPosture, at: Int64, durationMillis: Int64)
    case implicitTransition(Generation, from: DisplayPosture, to: DisplayPosture, at: Int64)
    case restorePlanned(Generation, flow: FlowID, degradations: [Degradation])
    case restoreApplied(Generation, flow: FlowID)
    case restoreRejected(Generation, flow: FlowID, reason: RestoreRejection)
}

public enum CaptureRejection: Sendable, Hashable, Codable {
    /// Offered generation is older than the open one.
    case stale(offered: Generation, current: Generation)
    /// Nothing is open; the flow answered a request that already settled.
    case noTransitionOpen
    /// Flow is not registered with the coordinator.
    case unknownFlow
}

public enum CheckpointRejection: Sendable, Hashable, Codable {
    /// Checkpoints are refused while a transition is open: the geometry the
    /// flow is describing is transient.
    case transitionInProgress
    case unknownFlow
}

public enum RestoreRejection: Sendable, Hashable, Codable {
    /// A newer generation has already settled; applying this plan would
    /// overwrite state that is more recent than it.
    case superseded(planned: Generation, current: Generation)
    case duplicate
    case unknownFlow
    /// No plan was ever issued for this flow in this generation.
    case noPlan
}

// MARK: - Journal

/// Bounded, append-only in spirit: the oldest entries fall off the front so
/// a long session cannot grow memory without limit. `capacity` is clamped to
/// at least 1 so an over-eager caller cannot create a journal that drops
/// everything.
public struct PostureJournal: Sendable, Hashable {
    public let capacity: Int
    public private(set) var events: [PostureEvent]
    /// How many events have been discarded from the front. Lets a consumer
    /// notice that a report is over a window, not the whole session.
    public private(set) var droppedCount: Int

    public init(capacity: Int = 512) {
        self.capacity = max(1, capacity)
        self.events = []
        self.droppedCount = 0
    }

    public mutating func append(_ event: PostureEvent) {
        events.append(event)
        if events.count > capacity {
            let overflow = events.count - capacity
            events.removeFirst(overflow)
            droppedCount = droppedCount > Int.max - overflow ? Int.max : droppedCount + overflow
        }
    }

    public var isEmpty: Bool { events.isEmpty }
    public var count: Int { events.count }

    public func report() -> ContinuityReport {
        ContinuityReport(events: events, droppedEvents: droppedCount)
    }
}

// MARK: - Report

/// The numbers a lead would put on a dashboard for a foldable launch.
public struct ContinuityReport: Sendable, Hashable {
    public var transitionsOpened: Int = 0
    public var transitionsSettled: Int = 0
    public var transitionsReverted: Int = 0
    public var implicitTransitions: Int = 0
    /// Extra `begin`s absorbed into an open transition.
    public var stormsAbsorbed: Int = 0
    public var capturesAccepted: Int = 0
    public var capturesRejected: Int = 0
    public var checkpointsRejected: Int = 0
    public var restoresPlanned: Int = 0
    public var restoresDegraded: Int = 0
    public var restoresApplied: Int = 0
    public var restoresRejected: Int = 0
    public var maxTransitionMillis: Int64 = 0
    public var degradationsByKind: [String: Int] = [:]
    public var droppedEvents: Int = 0

    public init() {}

    public init(events: [PostureEvent], droppedEvents: Int) {
        self.droppedEvents = droppedEvents
        for event in events {
            switch event {
            case .baselineSettled:
                break
            case .transitionOpened:
                transitionsOpened += 1
            case .transitionContinued:
                stormsAbsorbed += 1
            case .captureAccepted:
                capturesAccepted += 1
            case .captureRejected:
                capturesRejected += 1
            case .checkpointAccepted:
                break
            case .checkpointRejected:
                checkpointsRejected += 1
            case .transitionReverted:
                transitionsReverted += 1
            case .transitionSettled(_, _, _, let duration):
                transitionsSettled += 1
                maxTransitionMillis = max(maxTransitionMillis, duration)
            case .implicitTransition:
                implicitTransitions += 1
            case .restorePlanned(_, _, let degradations):
                restoresPlanned += 1
                if !degradations.isEmpty { restoresDegraded += 1 }
                for degradation in degradations {
                    let key = Self.kind(of: degradation)
                    degradationsByKind[key, default: 0] += 1
                }
            case .restoreApplied:
                restoresApplied += 1
            case .restoreRejected:
                restoresRejected += 1
            }
        }
    }

    /// Fraction of planned restores that were degraded, `0...1`. Zero when
    /// nothing was planned — a division that cannot fail.
    public var degradedRestoreRate: Double {
        guard restoresPlanned > 0 else { return 0 }
        return Double(restoresDegraded) / Double(restoresPlanned)
    }

    static func kind(of degradation: Degradation) -> String {
        switch degradation {
        case .captureMissed: return "captureMissed"
        case .noCaptureWindow: return "noCaptureWindow"
        case .focusDropped: return "focusDropped"
        case .noStateOfRecord: return "noStateOfRecord"
        }
    }
}

// MARK: - Invariants

/// Replays an event log and checks the ordering contract independently of
/// the coordinator that produced it. This is the check the tests feed
/// deliberately broken logs to — a checker that cannot fail is decoration.
public enum ContinuityInvariants {
    public enum Violation: Sendable, Hashable, CustomStringConvertible {
        /// A restore for generation `g` was applied after generation `g'` > g
        /// had settled. The flow now shows older state than it had.
        case restoreAfterSupersession(applied: Generation, currentSettled: Generation, flow: FlowID)
        /// The same flow applied the same generation's restore twice.
        case duplicateRestore(Generation, flow: FlowID)
        /// A capture was accepted for a generation that was not open.
        case captureOutsideTransition(Generation, flow: FlowID)
        /// A transition opened while another was already open (the journal
        /// should show `transitionContinued` instead).
        case nestedTransitionOpened(Generation)
        /// A transition settled that was never opened.
        case settleWithoutOpen(Generation)
        /// A restore was applied for a generation that never planned one.
        case restoreWithoutPlan(Generation, flow: FlowID)

        public var description: String {
            switch self {
            case .restoreAfterSupersession(let applied, let current, let flow):
                return "restore \(applied) applied for \(flow) after \(current) settled"
            case .duplicateRestore(let generation, let flow):
                return "duplicate restore \(generation) for \(flow)"
            case .captureOutsideTransition(let generation, let flow):
                return "capture \(generation) for \(flow) accepted with no open transition"
            case .nestedTransitionOpened(let generation):
                return "transition \(generation) opened while another was open"
            case .settleWithoutOpen(let generation):
                return "transition \(generation) settled but was never opened"
            case .restoreWithoutPlan(let generation, let flow):
                return "restore \(generation) applied for \(flow) with no plan"
            }
        }
    }

    public static func validate(_ events: [PostureEvent]) -> [Violation] {
        var violations: [Violation] = []
        var openGeneration: Generation?
        var lastSettled: Generation?
        var planned: Set<PlanKey> = []
        var applied: Set<PlanKey> = []

        for event in events {
            switch event {
            case .baselineSettled, .checkpointAccepted, .checkpointRejected,
                 .captureRejected, .restoreRejected:
                break
            case .transitionOpened(let generation, _, _, _):
                if openGeneration != nil { violations.append(.nestedTransitionOpened(generation)) }
                openGeneration = generation
            case .transitionContinued:
                break
            case .captureAccepted(let generation, let flow):
                if openGeneration != generation {
                    violations.append(.captureOutsideTransition(generation, flow: flow))
                }
            case .transitionReverted(let generation, _, _):
                if openGeneration == nil { violations.append(.settleWithoutOpen(generation)) }
                openGeneration = nil
            case .transitionSettled(let generation, _, _, _):
                if openGeneration == nil { violations.append(.settleWithoutOpen(generation)) }
                openGeneration = nil
                lastSettled = generation
            case .implicitTransition(let generation, _, _, _):
                lastSettled = generation
            case .restorePlanned(let generation, let flow, _):
                planned.insert(PlanKey(generation: generation, flow: flow))
            case .restoreApplied(let generation, let flow):
                let key = PlanKey(generation: generation, flow: flow)
                if !planned.contains(key) {
                    violations.append(.restoreWithoutPlan(generation, flow: flow))
                }
                if applied.contains(key) {
                    violations.append(.duplicateRestore(generation, flow: flow))
                }
                applied.insert(key)
                if let lastSettled, generation < lastSettled {
                    violations.append(.restoreAfterSupersession(
                        applied: generation, currentSettled: lastSettled, flow: flow))
                }
            }
        }
        return violations
    }

    struct PlanKey: Hashable {
        var generation: Generation
        var flow: FlowID
    }
}
