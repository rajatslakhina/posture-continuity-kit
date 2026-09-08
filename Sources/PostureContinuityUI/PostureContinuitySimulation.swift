#if canImport(SwiftUI)
import SwiftUI
import PostureContinuity

/// One simulated flow — a checkout with a scrolling order list, an e-mail
/// field, a detail pane and a sheet — driven through fold/unfold postures by
/// the real `ContinuityCoordinator`. Every button is a real call into the
/// library; the only thing simulated is the hardware.
@MainActor
public final class PostureContinuitySimulation: ObservableObject {
    public struct LogLine: Identifiable, Sendable {
        public let id: Int
        public let text: String
    }

    public static let checkoutFlow = FlowID("checkout")
    public static let emailField = "email"
    public static let promoField = "promo-code"
    public static let addressSheet = "address-picker"

    // Posture / coordinator state
    @Published public private(set) var posture: DisplayPosture?
    @Published public private(set) var phase: PosturePhase = .settled
    @Published public private(set) var layoutMode: LayoutMode = .singleColumn
    @Published public private(set) var lastPlan: RestorePlan?
    @Published public private(set) var lastOutcome: String = "—"
    @Published public private(set) var report = ContinuityReport()
    @Published public private(set) var violations: [ContinuityInvariants.Violation] = []
    @Published public private(set) var log: [LogLine] = []
    @Published public private(set) var isBusy = false

    // Live flow state — what the user actually sees and edits
    @Published public var draftEmail: String = ""
    @Published public var navigation = NavigationState(stack: [.list])
    @Published public var topItemID: String? = nil
    @Published public var focusedField: String? = nil
    @Published public var sheetPresented = false

    /// Off, and the demo behaves like an app that never heard of continuity:
    /// the layout changes and whatever the view hierarchy forgets is gone.
    @Published public var restoreEnabled = true

    public let items: [String]
    public let coordinator: ContinuityCoordinator
    private var clockMillis: Int64 = 0
    private var logCounter = 0

    public init(registry: LayoutPolicyRegistry, interpreter: PostureInterpreter = PostureInterpreter()) {
        self.items = (0..<48).map { "item-\($0)" }
        self.coordinator = ContinuityCoordinator(
            configuration: .init(interpreter: interpreter, registry: registry, journalCapacity: 256))
    }

    // MARK: Lifecycle

    public func start() async {
        await coordinator.register(FlowDescriptor(
            id: Self.checkoutFlow,
            fieldsBySingleColumn: [Self.emailField],
            fieldsByTwoColumn: [Self.emailField, Self.promoField]))
        let outcome = await coordinator.ingest(PostureKeyword.compact.observation(at: tick()))
        if case .baseline(let baseline) = outcome {
            posture = baseline
            layoutMode = await coordinator.layoutMode(for: Self.checkoutFlow) ?? .singleColumn
            append("baseline \(describe(baseline))")
        }
        topItemID = items.first
        await checkpointNow()
        await refreshMetrics()
    }

    /// Records the live state as the settled state of record.
    public func checkpointNow() async {
        let verdict = await coordinator.checkpoint(liveSnapshot())
        append("checkpoint → \(verdict)")
        await refreshMetrics()
    }

    // MARK: Driving postures

    /// A real fold: a transitioning observation (capture window), a short
    /// pause so the frozen state is visible, then the settled posture.
    public func move(to keyword: PostureKeyword, pauseMillis: UInt64 = 450) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await ingest(PostureKeyword.transitioning.observation(at: tick(120)))
        try? await Task.sleep(nanoseconds: pauseMillis * 1_000_000)
        await ingest(keyword.observation(at: tick(Int64(clamping: pauseMillis))))
    }

    /// Fold, fold, unfold inside one transition. The coordinator should
    /// absorb the extra begins and, if it ends where it began, restore nothing.
    public func storm(returningTo keyword: PostureKeyword) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        for _ in 0..<3 {
            await ingest(PostureKeyword.transitioning.observation(at: tick(60)))
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        await ingest(keyword.observation(at: tick(200)))
    }

    /// Jump straight to a settled posture with no transitioning observation —
    /// what a resizable-simulator drag looks like from inside the app.
    public func jump(to keyword: PostureKeyword) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await ingest(keyword.observation(at: tick(50)))
    }

    /// Runs a script such as `transitioning@100,expanded@600,transitioning@800,book@1200`.
    public func run(scriptText: String) async {
        guard !isBusy else { return }
        switch PostureScript.parse(scriptText) {
        case .failure(let error):
            append("script rejected: \(error)")
        case .success(let script):
            isBusy = true
            defer { isBusy = false }
            append("script: \(script.steps.count) steps")
            var previous = script.steps.first?.atMillis ?? 0
            for step in script.steps {
                let delta = max(0, step.atMillis &- previous)
                if delta > 0 { try? await Task.sleep(nanoseconds: UInt64(min(delta, 2_000)) * 1_000_000) }
                previous = step.atMillis
                await ingest(step.keyword.observation(at: tick(delta)))
            }
        }
    }

    // MARK: Ingest + apply

    private func ingest(_ observation: PostureObservation) async {
        let outcome = await coordinator.ingest(observation)
        switch outcome {
        case .baseline(let baseline):
            posture = baseline
            phase = .settled
            append("baseline \(describe(baseline))")

        case .transitionOpened(let ticket):
            phase = .transitioning
            posture = ticket.toward
            let verdict = await coordinator.capture(liveSnapshot(), generation: ticket.generation)
            append("\(ticket.generation) opened → capture \(verdict)")

        case .transitionContinued(let generation):
            phase = .transitioning
            append("\(generation) continued (storm absorbed; snapshot of record unchanged)")

        case .settle(let settle):
            phase = .settled
            switch settle {
            case .unchanged:
                append("settled: unchanged")
            case .reverted(let generation, let storms):
                posture = await coordinator.currentPosture
                lastOutcome = "\(generation) reverted after \(storms) storm(s) — nothing restored"
                append(lastOutcome)
            case .settled(let bundle):
                posture = bundle.posture
                await apply(bundle, implicit: false)
            case .implicit(let bundle):
                posture = bundle.posture
                await apply(bundle, implicit: true)
            }
        }
        await refreshMetrics()
    }

    private func apply(_ bundle: RestoreBundle, implicit: Bool) async {
        guard let plan = bundle.plan(for: Self.checkoutFlow) else { return }
        lastPlan = plan
        layoutMode = plan.targetMode

        if restoreEnabled {
            // The whole point: put the user back where they were, in the new
            // layout's terms, with the coordinator's projection applied.
            navigation = plan.snapshot.navigation
            focusedField = plan.snapshot.focus?.fieldID
            draftEmail = plan.snapshot.draft[Self.emailField] ?? draftEmail
            sheetPresented = plan.snapshot.sheets.contains(Self.addressSheet)
            topItemID = plan.snapshot.scroll?.itemID ?? items.first
            let verdict = await coordinator.acknowledgeRestore(Self.checkoutFlow, generation: plan.generation)
            lastOutcome = "\(plan.generation)\(implicit ? " implicit" : "") → restored from \(describe(plan.provenance))"
                + (plan.isDegraded ? " · degraded: \(plan.degradations)" : "")
                + " · ack \(verdict)"
        } else {
            // Naive app: layout changes, SwiftUI rebuilds the subtree, and the
            // navigation / focus / scroll position evaporate.
            navigation = plan.targetMode.isTwoColumn ? NavigationState(stack: []) : NavigationState(stack: [.list])
            focusedField = nil
            sheetPresented = false
            topItemID = items.first
            lastOutcome = "\(plan.generation) → restore disabled: state discarded (naive behaviour)"
        }
        append(lastOutcome)
    }

    // MARK: Snapshots

    public func liveSnapshot() -> ContinuitySnapshot {
        ContinuitySnapshot(
            flow: Self.checkoutFlow,
            scroll: topItemID.map { ScrollAnchor(itemID: $0) },
            focus: focusedField.map { FocusTarget(fieldID: $0) },
            navigation: navigation,
            sheets: sheetPresented ? [Self.addressSheet] : [],
            draft: [Self.emailField: draftEmail])
    }

    // MARK: Helpers

    private func refreshMetrics() async {
        report = await coordinator.report()
        violations = await coordinator.violations()
    }

    private func tick(_ delta: Int64 = 0) -> Int64 {
        let step = max(0, delta)
        clockMillis = clockMillis > Int64.max - step ? Int64.max : clockMillis + step
        return clockMillis
    }

    private func append(_ text: String) {
        logCounter += 1
        log.insert(LogLine(id: logCounter, text: text), at: 0)
        if log.count > 60 { log.removeLast(log.count - 60) }
    }

    func describe(_ posture: DisplayPosture) -> String {
        let hinge = posture.hinge.map { " hinge:\($0.axis.rawValue)@\(Sanitize.saturatingInt($0.separatorFraction * 100))%" } ?? ""
        let width = Sanitize.saturatingInt(posture.size.width)
        let height = Sanitize.saturatingInt(posture.size.height)
        return "\(posture.layoutClass.rawValue) \(width)×\(height)\(hinge)"
    }

    func describe(_ provenance: SnapshotProvenance) -> String {
        switch provenance {
        case .captured(let generation): return "capture \(generation)"
        case .checkpoint: return "checkpoint"
        case .none: return "nothing"
        }
    }

    public var modeDescription: String {
        switch layoutMode {
        case .singleColumn: return "one column"
        case .twoColumn(let fraction): return "two columns · sidebar \(Sanitize.saturatingInt(fraction * 100))%"
        }
    }
}
#endif
