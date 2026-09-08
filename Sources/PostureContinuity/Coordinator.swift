import Foundation

// MARK: - Outcomes

/// Handed back from `beginTransition`. The app fans the capture request out
/// to every registered flow; each answers with `capture(_:generation:)`.
public struct TransitionTicket: Sendable, Hashable {
    public var generation: Generation
    public var origin: DisplayPosture
    public var toward: DisplayPosture
    /// Flows the coordinator expects a capture from, in stable order.
    public var flowsToCapture: [FlowID]
}

public enum CaptureVerdict: Sendable, Hashable {
    case accepted(Generation)
    case rejected(CaptureRejection)
}

public enum CheckpointVerdict: Sendable, Hashable {
    case accepted
    case rejected(CheckpointRejection)
}

public enum RestoreVerdict: Sendable, Hashable {
    case applied
    case rejected(RestoreRejection)
}

/// Where the snapshot in a plan came from. Surfaced so a view can decide to
/// animate a captured restore but not a degraded one, and so analytics can
/// count the difference.
public enum SnapshotProvenance: Sendable, Hashable, Codable {
    case captured(Generation)
    case checkpoint
    case none
}

public struct RestorePlan: Sendable, Hashable {
    public var generation: Generation
    public var flow: FlowID
    public var sourceMode: LayoutMode
    public var targetMode: LayoutMode
    public var snapshot: ContinuitySnapshot
    public var provenance: SnapshotProvenance
    public var degradations: [Degradation]

    public var isDegraded: Bool { !degradations.isEmpty }
}

public struct RestoreBundle: Sendable, Hashable {
    public var generation: Generation
    public var posture: DisplayPosture
    /// Sorted by flow identifier so the same inputs always yield the same
    /// order — a diff of two bundles in a test is meaningful.
    public var plans: [RestorePlan]

    public func plan(for flow: FlowID) -> RestorePlan? {
        plans.first { $0.flow == flow }
    }
}

public enum SettleOutcome: Sendable, Hashable {
    /// The transition ended where it began; nothing to restore.
    case reverted(Generation, storms: Int)
    case settled(RestoreBundle)
    /// The posture changed with no open transition; plans are degraded.
    case implicit(RestoreBundle)
    /// Same settled posture as before; nothing happened.
    case unchanged
}

public enum IngestOutcome: Sendable, Hashable {
    case baseline(DisplayPosture)
    case transitionOpened(TransitionTicket)
    case transitionContinued(Generation)
    case settle(SettleOutcome)
}

// MARK: - Coordinator

/// The state machine. One per scene.
///
/// Every method is synchronous inside the actor — there is no `await` in any
/// body here. That is a deliberate concurrency guarantee, not a style choice:
/// an actor method that suspends can interleave with another call, and a
/// `read → await → write` in `settle` would let a second fold plan against
/// state the first fold had already replaced. Callers suspend; the
/// coordinator computes.
///
/// Lifecycle per transition:
/// 1. `beginTransition` (or `ingest` of a transitioning observation) opens a
///    generation and returns the flows to capture.
/// 2. Flows answer with `capture`. Late or stale answers are rejected and
///    journaled; the flow's last settled checkpoint stands in.
/// 3. `settle` closes the generation and issues one `RestorePlan` per flow —
///    or reports `reverted` if the display ended where it started, in which
///    case nothing is restored and no live state is disturbed.
/// 4. Flows `acknowledgeRestore`. A plan from a generation that a newer
///    settle has superseded is rejected: applying it would roll the user back.
public actor ContinuityCoordinator {
    public struct Configuration: Sendable {
        public var interpreter: PostureInterpreter
        public var registry: LayoutPolicyRegistry
        public var journalCapacity: Int

        public init(
            interpreter: PostureInterpreter = PostureInterpreter(),
            registry: LayoutPolicyRegistry = LayoutPolicyRegistry(),
            journalCapacity: Int = 512
        ) {
            self.interpreter = interpreter
            self.registry = registry
            self.journalCapacity = journalCapacity
        }
    }

    private struct FlowRecord {
        var descriptor: FlowDescriptor
        var checkpoint: ContinuitySnapshot?
    }

    private struct OpenTransition {
        var generation: Generation
        var origin: DisplayPosture
        var toward: DisplayPosture
        var openedAt: Int64
        var captures: [FlowID: ContinuitySnapshot]
        var storms: Int
    }

    public let configuration: Configuration

    private var flows: [FlowID: FlowRecord] = [:]
    private var settledPosture: DisplayPosture?
    private var open: OpenTransition?
    private var lastIssued = Generation(0)
    private var lastSettledGeneration: Generation?
    private var outstandingPlans: [FlowID: RestorePlan] = [:]
    /// The generation each flow most recently applied. One entry per flow,
    /// never more: the supersession guard already refuses anything older than
    /// the last settled generation, so duplicate detection only needs the
    /// latest applied generation, not a history of every (generation, flow).
    private var lastAppliedGeneration: [FlowID: Generation] = [:]
    private var journal: PostureJournal

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.journal = PostureJournal(capacity: configuration.journalCapacity)
    }

    // MARK: Registration

    public func register(_ descriptor: FlowDescriptor) {
        if var existing = flows[descriptor.id] {
            existing.descriptor = descriptor
            flows[descriptor.id] = existing
        } else {
            flows[descriptor.id] = FlowRecord(descriptor: descriptor, checkpoint: nil)
        }
    }

    public func unregister(_ flow: FlowID) {
        flows[flow] = nil
        outstandingPlans[flow] = nil
        lastAppliedGeneration[flow] = nil
        open?.captures[flow] = nil
    }

    public var registeredFlows: [FlowID] {
        flows.keys.sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: State of record

    /// Record settled state for a flow. Refused while a transition is open:
    /// whatever the flow is describing at that moment is the transient
    /// layout, and recording it would poison the next restore.
    @discardableResult
    public func checkpoint(_ snapshot: ContinuitySnapshot) -> CheckpointVerdict {
        guard flows[snapshot.flow] != nil else {
            journal.append(.checkpointRejected(flow: snapshot.flow, reason: .unknownFlow))
            return .rejected(.unknownFlow)
        }
        guard open == nil else {
            journal.append(.checkpointRejected(flow: snapshot.flow, reason: .transitionInProgress))
            return .rejected(.transitionInProgress)
        }
        flows[snapshot.flow]?.checkpoint = snapshot
        journal.append(.checkpointAccepted(flow: snapshot.flow))
        return .accepted
    }

    public func checkpoint(for flow: FlowID) -> ContinuitySnapshot? {
        flows[flow]?.checkpoint
    }

    // MARK: Observation ingest

    /// Drives the machine from raw observations. The interpreter decides
    /// what the observation means; this decides what to do about it.
    @discardableResult
    public func ingest(_ observation: PostureObservation) -> IngestOutcome {
        let posture = configuration.interpreter.interpret(observation)
        let at = observation.timestampMillis

        guard settledPosture != nil else {
            // First observation is the baseline. If it is mid-transition we
            // still record it: something is better than nothing, and the
            // first settle will plan against it.
            settledPosture = DisplayPosture(
                layoutClass: posture.layoutClass, phase: .settled, size: posture.size, hinge: posture.hinge)
            journal.append(.baselineSettled(posture, at: at))
            return .baseline(posture)
        }

        switch posture.phase {
        case .transitioning:
            if open != nil {
                return .transitionContinued(continueTransition(toward: posture, at: at))
            }
            return .transitionOpened(beginTransition(toward: posture, at: at))
        case .settled:
            return .settle(settle(at: posture, at: at))
        }
    }

    // MARK: Transition lifecycle

    /// Opens a generation. If one is already open this is a storm — the
    /// target is updated and the same generation is returned, because the
    /// snapshot of record is still the last settled state and must not be
    /// replaced by whatever the flows look like mid-transition.
    @discardableResult
    public func beginTransition(toward: DisplayPosture, at: Int64) -> TransitionTicket {
        if let existing = open {
            let generation = continueTransition(toward: toward, at: at)
            return TransitionTicket(
                generation: generation, origin: existing.origin, toward: toward, flowsToCapture: [])
        }
        let origin = settledPosture ?? DisplayPosture(
            layoutClass: toward.layoutClass, phase: .settled, size: toward.size, hinge: toward.hinge)
        let generation = lastIssued.next()
        lastIssued = generation
        open = OpenTransition(
            generation: generation, origin: origin, toward: toward, openedAt: at, captures: [:], storms: 0)
        journal.append(.transitionOpened(generation, from: origin, toward: toward, at: at))
        return TransitionTicket(
            generation: generation, origin: origin, toward: toward, flowsToCapture: registeredFlows)
    }

    private func continueTransition(toward: DisplayPosture, at: Int64) -> Generation {
        guard var existing = open else {
            return beginTransition(toward: toward, at: at).generation
        }
        existing.toward = toward
        existing.storms = existing.storms == Int.max ? Int.max : existing.storms + 1
        open = existing
        journal.append(.transitionContinued(existing.generation, toward: toward, at: at))
        return existing.generation
    }

    /// A flow's answer to a capture request.
    @discardableResult
    public func capture(_ snapshot: ContinuitySnapshot, generation: Generation) -> CaptureVerdict {
        guard flows[snapshot.flow] != nil else {
            journal.append(.captureRejected(generation, flow: snapshot.flow, reason: .unknownFlow))
            return .rejected(.unknownFlow)
        }
        guard var existing = open else {
            journal.append(.captureRejected(generation, flow: snapshot.flow, reason: .noTransitionOpen))
            return .rejected(.noTransitionOpen)
        }
        guard existing.generation == generation else {
            let reason = CaptureRejection.stale(offered: generation, current: existing.generation)
            journal.append(.captureRejected(generation, flow: snapshot.flow, reason: reason))
            return .rejected(reason)
        }
        existing.captures[snapshot.flow] = snapshot
        open = existing
        journal.append(.captureAccepted(generation, flow: snapshot.flow))
        return .accepted(generation)
    }

    /// Closes the open generation at a settled posture.
    @discardableResult
    public func settle(at posture: DisplayPosture, at: Int64) -> SettleOutcome {
        let settled = DisplayPosture(
            layoutClass: posture.layoutClass, phase: .settled, size: posture.size, hinge: posture.hinge)

        guard let transition = open else {
            // No transition was open. Either nothing changed, or the posture
            // jumped straight to a new settled state (resizable simulator
            // drag, iPad window resize) and there was no capture window.
            guard let previous = settledPosture, !previous.isEquivalent(to: settled) else {
                settledPosture = settled
                return .unchanged
            }
            let generation = lastIssued.next()
            lastIssued = generation
            journal.append(.implicitTransition(generation, from: previous, to: settled, at: at))
            let bundle = plan(
                generation: generation, from: previous, to: settled, captures: [:],
                extraDegradation: .noCaptureWindow)
            commit(bundle)
            return .implicit(bundle)
        }

        open = nil

        if transition.origin.isEquivalent(to: settled) {
            // Fold → unfold inside the transition: the user is back where
            // they started and their live state was never disturbed.
            settledPosture = settled
            journal.append(.transitionReverted(transition.generation, at: at, storms: transition.storms))
            return .reverted(transition.generation, storms: transition.storms)
        }

        let duration = at >= transition.openedAt ? at &- transition.openedAt : 0
        journal.append(.transitionSettled(transition.generation, posture: settled, at: at, durationMillis: duration))
        let bundle = plan(
            generation: transition.generation, from: transition.origin, to: settled,
            captures: transition.captures, extraDegradation: nil)
        commit(bundle)
        return .settled(bundle)
    }

    private func plan(
        generation: Generation,
        from origin: DisplayPosture,
        to target: DisplayPosture,
        captures: [FlowID: ContinuitySnapshot],
        extraDegradation: Degradation?
    ) -> RestoreBundle {
        var plans: [RestorePlan] = []
        for flow in registeredFlows {
            guard let record = flows[flow] else { continue }
            let sourceMode = configuration.registry.resolve(flow, in: origin)
            let targetMode = configuration.registry.resolve(flow, in: target)

            var degradations: [Degradation] = []
            if let extra = extraDegradation { degradations.append(extra) }

            let snapshot: ContinuitySnapshot
            let provenance: SnapshotProvenance
            if let captured = captures[flow] {
                snapshot = captured
                provenance = .captured(generation)
            } else if let checkpoint = record.checkpoint {
                snapshot = checkpoint
                provenance = .checkpoint
                if extraDegradation == nil { degradations.append(.captureMissed) }
            } else {
                snapshot = ContinuitySnapshot(flow: flow)
                provenance = .none
                degradations.append(.noStateOfRecord)
            }

            let projected = SnapshotProjector.project(
                snapshot, from: sourceMode, to: targetMode, descriptor: record.descriptor)
            degradations.append(contentsOf: projected.degradations)

            plans.append(RestorePlan(
                generation: generation, flow: flow, sourceMode: sourceMode, targetMode: targetMode,
                snapshot: projected.snapshot, provenance: provenance, degradations: degradations))
        }
        return RestoreBundle(generation: generation, posture: target, plans: plans)
    }

    private func commit(_ bundle: RestoreBundle) {
        settledPosture = bundle.posture
        lastSettledGeneration = bundle.generation
        for plan in bundle.plans {
            outstandingPlans[plan.flow] = plan
            // The projected snapshot is now the state of record in the new
            // layout, so a storm that follows immediately has something
            // trustworthy to plan from even if the flow has not re-checkpointed.
            if plan.provenance != .none {
                flows[plan.flow]?.checkpoint = plan.snapshot
            }
            journal.append(.restorePlanned(plan.generation, flow: plan.flow, degradations: plan.degradations))
        }
    }

    /// A flow reports that it applied its plan. The ordering guard lives
    /// here: a plan whose generation is older than the last settled one is
    /// refused, because applying it would show the user state from before a
    /// transition that has already completed.
    @discardableResult
    public func acknowledgeRestore(_ flow: FlowID, generation: Generation) -> RestoreVerdict {
        guard flows[flow] != nil else {
            journal.append(.restoreRejected(generation, flow: flow, reason: .unknownFlow))
            return .rejected(.unknownFlow)
        }
        if let current = lastSettledGeneration, generation < current {
            let reason = RestoreRejection.superseded(planned: generation, current: current)
            journal.append(.restoreRejected(generation, flow: flow, reason: reason))
            return .rejected(reason)
        }
        guard let plan = outstandingPlans[flow], plan.generation == generation else {
            journal.append(.restoreRejected(generation, flow: flow, reason: .noPlan))
            return .rejected(.noPlan)
        }
        guard lastAppliedGeneration[flow] != generation else {
            journal.append(.restoreRejected(generation, flow: flow, reason: .duplicate))
            return .rejected(.duplicate)
        }
        lastAppliedGeneration[flow] = generation
        journal.append(.restoreApplied(generation, flow: flow))
        return .applied
    }

    // MARK: Queries

    public var currentPosture: DisplayPosture? { settledPosture }
    public var isTransitioning: Bool { open != nil }
    public var openGeneration: Generation? { open?.generation }
    public var settledGeneration: Generation? { lastSettledGeneration }

    public func outstandingPlan(for flow: FlowID) -> RestorePlan? {
        outstandingPlans[flow]
    }

    /// The mode a flow should render in right now, against the last settled
    /// posture. `nil` before the first observation.
    public func layoutMode(for flow: FlowID) -> LayoutMode? {
        guard let posture = settledPosture else { return nil }
        return configuration.registry.resolve(flow, in: posture)
    }

    public func journalSnapshot() -> PostureJournal { journal }
    public func report() -> ContinuityReport { journal.report() }
    /// Validates the journal. Once the bounded journal has dropped its oldest
    /// entries the log is a window, not a session, so the checker is told so
    /// and does not report the missing prefix as violations.
    public func violations() -> [ContinuityInvariants.Violation] {
        ContinuityInvariants.validate(journal.events, windowed: journal.droppedCount > 0)
    }
}
