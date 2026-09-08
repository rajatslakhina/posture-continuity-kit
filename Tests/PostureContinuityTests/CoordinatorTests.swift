import XCTest
@testable import PostureContinuity

final class CoordinatorTests: XCTestCase {
    func testFirstObservationIsBaselineAndPlansNothing() async {
        let coordinator = await Fixtures.coordinator()
        let outcome = await coordinator.ingest(PostureKeyword.compact.observation(at: 0))
        guard case .baseline(let posture) = outcome else { return XCTFail("expected baseline, got \(outcome)") }
        XCTAssertEqual(posture.layoutClass, .compact)
        let current = await coordinator.currentPosture
        XCTAssertEqual(current?.phase, .settled)
        let mode = await coordinator.layoutMode(for: Fixtures.checkout)
        XCTAssertEqual(mode, .singleColumn)
    }

    func testCapturedSnapshotIsProjectedIntoTheNewLayout() async {
        let coordinator = await Fixtures.coordinator()
        await coordinator.ingest(PostureKeyword.compact.observation(at: 0))
        await coordinator.checkpoint(Fixtures.checkoutSnapshot())

        let ticket = await coordinator.ingest(PostureKeyword.transitioning.observation(at: 100)).ticket
        XCTAssertEqual(ticket?.generation, Generation(1))
        XCTAssertEqual(ticket?.flowsToCapture, [Fixtures.checkout, Fixtures.search])

        // The user scrolled since the last checkpoint; the capture is fresher.
        var fresh = Fixtures.checkoutSnapshot()
        fresh.scroll = ScrollAnchor(itemID: "item-12", offsetWithinItem: 0.8)
        let verdict = await coordinator.capture(fresh, generation: Generation(1))
        XCTAssertEqual(verdict, .accepted(Generation(1)))

        let outcome = await coordinator.ingest(PostureKeyword.expanded.observation(at: 500)).settleOutcome
        guard case .settled(let bundle) = outcome else { return XCTFail("expected settled, got \(String(describing: outcome))") }
        XCTAssertEqual(bundle.generation, Generation(1))
        XCTAssertEqual(bundle.plans.map(\.flow), [Fixtures.checkout, Fixtures.search], "deterministic order")

        let plan = bundle.plan(for: Fixtures.checkout)
        XCTAssertEqual(plan?.provenance, .captured(Generation(1)))
        XCTAssertEqual(plan?.sourceMode, .singleColumn)
        XCTAssertEqual(plan?.targetMode, .split(0.38))
        XCTAssertEqual(plan?.snapshot.scroll?.itemID, "item-12", "the capture, not the stale checkpoint")
        XCTAssertEqual(plan?.snapshot.navigation, NavigationState(stack: [], selection: "order-1"), "stack became a selection")
        XCTAssertEqual(plan?.snapshot.focus?.fieldID, "email")
        XCTAssertEqual(plan?.degradations, [])

        // Search never checkpointed and never captured: restored to empty, and
        // the plan says so rather than pretending.
        let search = bundle.plan(for: Fixtures.search)
        XCTAssertEqual(search?.provenance, SnapshotProvenance.none)
        XCTAssertEqual(search?.degradations, [.noStateOfRecord])

        let applied = await coordinator.acknowledgeRestore(Fixtures.checkout, generation: Generation(1))
        XCTAssertEqual(applied, .applied)
        let violations = await coordinator.violations()
        XCTAssertEqual(violations, [])
    }

    func testMissedCaptureFallsBackToCheckpointAndIsCountedAsDegraded() async {
        let coordinator = await Fixtures.coordinator()
        await coordinator.ingest(PostureKeyword.compact.observation(at: 0))
        await coordinator.checkpoint(Fixtures.checkoutSnapshot())
        await coordinator.ingest(PostureKeyword.transitioning.observation(at: 100))
        let bundle = await coordinator.ingest(PostureKeyword.expanded.observation(at: 500)).settleOutcome?.bundle
        let plan = bundle?.plan(for: Fixtures.checkout)
        XCTAssertEqual(plan?.provenance, .checkpoint)
        XCTAssertEqual(plan?.degradations, [.captureMissed])
        XCTAssertEqual(plan?.snapshot.scroll?.itemID, "item-7")
        let report = await coordinator.report()
        XCTAssertEqual(report.restoresDegraded, 2, "checkout (missed capture) and search (no state)")
        XCTAssertEqual(report.degradationsByKind["captureMissed"], 1)
    }

    func testFocusOnTwoColumnOnlyFieldIsDroppedOnFold() async {
        let coordinator = await Fixtures.coordinator()
        await coordinator.ingest(PostureKeyword.expanded.observation(at: 0))
        var editing = Fixtures.checkoutSnapshot(focus: "promo-code")
        editing.navigation = NavigationState(stack: [], selection: "order-1")
        await coordinator.checkpoint(editing)
        await coordinator.ingest(PostureKeyword.transitioning.observation(at: 100))
        await coordinator.capture(editing, generation: Generation(1))
        let plan = await coordinator.ingest(PostureKeyword.compact.observation(at: 400)).settleOutcome?.bundle?.plan(for: Fixtures.checkout)
        XCTAssertNil(plan?.snapshot.focus)
        XCTAssertEqual(plan?.degradations, [.focusDropped(field: "promo-code")])
        XCTAssertEqual(plan?.snapshot.navigation, NavigationState(stack: [.list, .detail("order-1")]))
    }

    func testStaleAndLateCapturesAreRejectedAndJournaled() async {
        let coordinator = await Fixtures.coordinator()
        await coordinator.ingest(PostureKeyword.compact.observation(at: 0))
        let early = await coordinator.capture(Fixtures.checkoutSnapshot(), generation: Generation(1))
        XCTAssertEqual(early, .rejected(.noTransitionOpen))

        await coordinator.ingest(PostureKeyword.transitioning.observation(at: 100))
        let wrongGeneration = await coordinator.capture(Fixtures.checkoutSnapshot(), generation: Generation(0))
        XCTAssertEqual(wrongGeneration, .rejected(.stale(offered: Generation(0), current: Generation(1))))
        let unknown = await coordinator.capture(ContinuitySnapshot(flow: FlowID("ghost")), generation: Generation(1))
        XCTAssertEqual(unknown, .rejected(.unknownFlow))

        await coordinator.ingest(PostureKeyword.expanded.observation(at: 500))
        let late = await coordinator.capture(Fixtures.checkoutSnapshot(), generation: Generation(1))
        XCTAssertEqual(late, .rejected(.noTransitionOpen), "the transition settled; a late capture describes the wrong layout")

        let report = await coordinator.report()
        XCTAssertEqual(report.capturesRejected, 4)
        XCTAssertEqual(report.capturesAccepted, 0)
    }

    func testCheckpointIsRefusedDuringTransition() async {
        let coordinator = await Fixtures.coordinator()
        await coordinator.ingest(PostureKeyword.compact.observation(at: 0))
        await coordinator.checkpoint(Fixtures.checkoutSnapshot())
        await coordinator.ingest(PostureKeyword.transitioning.observation(at: 100))
        var midTransition = Fixtures.checkoutSnapshot()
        midTransition.scroll = ScrollAnchor(itemID: "garbage-mid-fold")
        let verdict = await coordinator.checkpoint(midTransition)
        XCTAssertEqual(verdict, .rejected(.transitionInProgress))
        let stored = await coordinator.checkpoint(for: Fixtures.checkout)
        XCTAssertEqual(stored?.scroll?.itemID, "item-7", "the settled checkpoint stands")
        let ghost = await coordinator.checkpoint(ContinuitySnapshot(flow: FlowID("ghost")))
        XCTAssertEqual(ghost, .rejected(.unknownFlow))
    }

    func testStormThatRevertsRestoresNothingAndKeepsTheCheckpoint() async {
        let coordinator = await Fixtures.coordinator()
        await coordinator.ingest(PostureKeyword.compact.observation(at: 0))
        await coordinator.checkpoint(Fixtures.checkoutSnapshot())

        let opened = await coordinator.ingest(PostureKeyword.transitioning.observation(at: 100))
        XCTAssertEqual(opened.ticket?.generation, Generation(1))
        let continued = await coordinator.ingest(PostureKeyword.transitioning.observation(at: 150))
        XCTAssertEqual(continued, .transitionContinued(Generation(1)), "same generation: the snapshot of record has not moved")
        let again = await coordinator.ingest(PostureKeyword.transitioning.observation(at: 200))
        XCTAssertEqual(again, .transitionContinued(Generation(1)))

        let outcome = await coordinator.ingest(PostureKeyword.compact.observation(at: 300)).settleOutcome
        XCTAssertEqual(outcome, .reverted(Generation(1), storms: 2))
        let plan = await coordinator.outstandingPlan(for: Fixtures.checkout)
        XCTAssertNil(plan, "nothing to restore: the user is where they started")
        let checkpoint = await coordinator.checkpoint(for: Fixtures.checkout)
        XCTAssertEqual(checkpoint, Fixtures.checkoutSnapshot())
        let settled = await coordinator.settledGeneration
        XCTAssertNil(settled, "a reverted transition does not supersede anything")
        let report = await coordinator.report()
        XCTAssertEqual(report.stormsAbsorbed, 2)
        XCTAssertEqual(report.transitionsReverted, 1)
        XCTAssertEqual(report.transitionsSettled, 0)

        // The next real transition gets the next generation, not a reused one.
        let next = await coordinator.ingest(PostureKeyword.transitioning.observation(at: 400)).ticket
        XCTAssertEqual(next?.generation, Generation(2))
    }

    func testStormThatEndsElsewherePlansFromTheOriginalCaptures() async {
        let coordinator = await Fixtures.coordinator()
        await coordinator.ingest(PostureKeyword.compact.observation(at: 0))
        await coordinator.ingest(PostureKeyword.transitioning.observation(at: 100))
        await coordinator.capture(Fixtures.checkoutSnapshot(), generation: Generation(1))
        await coordinator.ingest(PostureKeyword.transitioning.observation(at: 150))
        let bundle = await coordinator.ingest(PostureKeyword.book.observation(at: 400)).settleOutcome?.bundle
        XCTAssertEqual(bundle?.generation, Generation(1))
        XCTAssertEqual(bundle?.plan(for: Fixtures.checkout)?.provenance, .captured(Generation(1)))
        let settledPosture = await coordinator.currentPosture
        XCTAssertEqual(settledPosture?.hinge?.axis, .vertical)
        let duration = await coordinator.report().maxTransitionMillis
        XCTAssertEqual(duration, 300, "measured from the first begin, not the last storm")
    }

    func testImplicitTransitionWhenPostureJumpsWithoutATransitioningObservation() async {
        let coordinator = await Fixtures.coordinator()
        await coordinator.ingest(PostureKeyword.compact.observation(at: 0))
        await coordinator.checkpoint(Fixtures.checkoutSnapshot())
        let outcome = await coordinator.ingest(PostureKeyword.expanded.observation(at: 50)).settleOutcome
        guard case .implicit(let bundle) = outcome else { return XCTFail("expected implicit, got \(String(describing: outcome))") }
        XCTAssertEqual(bundle.generation, Generation(1))
        let plan = bundle.plan(for: Fixtures.checkout)
        XCTAssertEqual(plan?.provenance, .checkpoint)
        XCTAssertEqual(plan?.degradations, [.noCaptureWindow], "not captureMissed: there was no window to miss")
        XCTAssertEqual(plan?.snapshot.navigation.selection, "order-1")
        let report = await coordinator.report()
        XCTAssertEqual(report.implicitTransitions, 1)
        XCTAssertEqual(report.transitionsOpened, 0)
    }

    func testSameSettledPostureIsUnchanged() async {
        let coordinator = await Fixtures.coordinator()
        await coordinator.ingest(PostureKeyword.compact.observation(at: 0))
        let outcome = await coordinator.ingest(.init(width: 392, height: 844, foldState: .folded, hingeAngleDegrees: 0, timestampMillis: 20)).settleOutcome
        XCTAssertEqual(outcome, .unchanged)
        let posture = await coordinator.currentPosture
        XCTAssertEqual(posture?.size.width, 392, "jitter is absorbed into the settled posture")
    }

    func testSupersededRestoreIsRefusedSoAFlowNeverRollsBack() async {
        let coordinator = await Fixtures.coordinator()
        await coordinator.ingest(PostureKeyword.compact.observation(at: 0))
        await coordinator.checkpoint(Fixtures.checkoutSnapshot())

        // Fold 1 → expanded (g1). The checkout view is slow and has not applied yet.
        await coordinator.ingest(PostureKeyword.transitioning.observation(at: 100))
        await coordinator.ingest(PostureKeyword.expanded.observation(at: 400))
        // Fold 2 → compact (g2) settles before the g1 restore is applied.
        await coordinator.ingest(PostureKeyword.transitioning.observation(at: 500))
        await coordinator.ingest(PostureKeyword.compact.observation(at: 800))

        let stale = await coordinator.acknowledgeRestore(Fixtures.checkout, generation: Generation(1))
        XCTAssertEqual(stale, .rejected(.superseded(planned: Generation(1), current: Generation(2))))
        let current = await coordinator.acknowledgeRestore(Fixtures.checkout, generation: Generation(2))
        XCTAssertEqual(current, .applied)
        let twice = await coordinator.acknowledgeRestore(Fixtures.checkout, generation: Generation(2))
        XCTAssertEqual(twice, .rejected(.duplicate))
        let future = await coordinator.acknowledgeRestore(Fixtures.checkout, generation: Generation(9))
        XCTAssertEqual(future, .rejected(.noPlan))
        let ghost = await coordinator.acknowledgeRestore(FlowID("ghost"), generation: Generation(2))
        XCTAssertEqual(ghost, .rejected(.unknownFlow))

        let violations = await coordinator.violations()
        XCTAssertEqual(violations, [], "the coordinator refused every bad restore, so the journal is clean")
        let report = await coordinator.report()
        XCTAssertEqual(report.restoresRejected, 4)
        XCTAssertEqual(report.restoresApplied, 1)
    }

    func testProjectedSnapshotBecomesTheCheckpointForAnImmediateSecondFold() async {
        let coordinator = await Fixtures.coordinator()
        await coordinator.ingest(PostureKeyword.compact.observation(at: 0))
        await coordinator.checkpoint(Fixtures.checkoutSnapshot())
        await coordinator.ingest(PostureKeyword.transitioning.observation(at: 100))
        await coordinator.ingest(PostureKeyword.expanded.observation(at: 400))
        // The view never re-checkpoints before the next fold.
        await coordinator.ingest(PostureKeyword.transitioning.observation(at: 450))
        let plan = await coordinator.ingest(PostureKeyword.compact.observation(at: 700)).settleOutcome?.bundle?.plan(for: Fixtures.checkout)
        XCTAssertEqual(plan?.sourceMode, .split(0.38))
        XCTAssertEqual(plan?.snapshot.navigation, NavigationState(stack: [.list, .detail("order-1")]),
                       "split → stack from the projected checkpoint, so the round trip is exact")
        // A flow that never had state stays `.none`, and is not promoted to a
        // phantom empty checkpoint by the projection step.
        let search = await coordinator.checkpoint(for: Fixtures.search)
        XCTAssertNil(search)
    }

    func testUnregisterDropsPendingWork() async {
        let coordinator = await Fixtures.coordinator()
        await coordinator.ingest(PostureKeyword.compact.observation(at: 0))
        await coordinator.ingest(PostureKeyword.transitioning.observation(at: 100))
        await coordinator.capture(Fixtures.checkoutSnapshot(), generation: Generation(1))
        await coordinator.unregister(Fixtures.checkout)
        let bundle = await coordinator.ingest(PostureKeyword.expanded.observation(at: 400)).settleOutcome?.bundle
        XCTAssertEqual(bundle?.plans.map(\.flow), [Fixtures.search])
        let flows = await coordinator.registeredFlows
        XCTAssertEqual(flows, [Fixtures.search])
    }

    func testPerFeaturePolicyMeansTwoFlowsDisagreeOnTheSamePosture() async {
        let registry = LayoutPolicyRegistry()
            .registering(AlwaysSingleColumnPolicy(), for: Fixtures.checkout)
            .registering(HingeAvoidingPolicy(base: WidthThresholdPolicy()), for: Fixtures.search)
        let coordinator = await Fixtures.coordinator(registry: registry)
        await coordinator.ingest(PostureKeyword.compact.observation(at: 0))
        await coordinator.ingest(PostureKeyword.transitioning.observation(at: 100))
        let bundle = await coordinator.ingest(PostureKeyword.book.observation(at: 400)).settleOutcome?.bundle
        XCTAssertEqual(bundle?.plan(for: Fixtures.checkout)?.targetMode, .singleColumn)
        XCTAssertEqual(bundle?.plan(for: Fixtures.search)?.targetMode, .split(0.5), "column boundary on the hinge")
    }

    func testScriptedReaderDrivesAFullSessionAndTheJournalValidates() async throws {
        let coordinator = await Fixtures.coordinator()
        await coordinator.ingest(PostureKeyword.compact.observation(at: 0))
        await coordinator.checkpoint(Fixtures.checkoutSnapshot())
        let script = try PostureScript.parse(
            "transitioning@100,transitioning@140,compact@300,transitioning@400,expanded@700,transitioning@900,book@1200").get()
        let outcomes = await coordinator.drive(ScriptedPostureReader(script: script))
        XCTAssertEqual(outcomes.count, 7)
        let report = await coordinator.report()
        XCTAssertEqual(report.transitionsOpened, 3)
        XCTAssertEqual(report.transitionsReverted, 1)
        XCTAssertEqual(report.transitionsSettled, 2)
        XCTAssertEqual(report.stormsAbsorbed, 1)
        let violations = await coordinator.violations()
        XCTAssertEqual(violations, [])
        let generation = await coordinator.settledGeneration
        XCTAssertEqual(generation, Generation(3))
    }

    func testReplayReaderReproducesARecordedSequence() async {
        let recorded = [
            PostureKeyword.compact.observation(at: 0),
            PostureKeyword.transitioning.observation(at: 10),
            PostureKeyword.expanded.observation(at: 20)
        ]
        let coordinator = await Fixtures.coordinator()
        let outcomes = await coordinator.drive(ReplayPostureReader(recorded))
        XCTAssertEqual(outcomes.count, 3)
        guard case .settle(.settled(let bundle)) = outcomes[2] else { return XCTFail("expected settled, got \(outcomes[2])") }
        XCTAssertEqual(bundle.posture.layoutClass, .expanded)
    }

    func testJournalIsBoundedUnderALongSession() async {
        let coordinator = ContinuityCoordinator(configuration: .init(journalCapacity: 16))
        await coordinator.register(Fixtures.searchDescriptor)
        await coordinator.ingest(PostureKeyword.compact.observation(at: 0))
        for i in 0..<100 {
            let base = Int64(i) * 100
            await coordinator.ingest(PostureKeyword.transitioning.observation(at: base + 10))
            await coordinator.ingest((i % 2 == 0 ? PostureKeyword.expanded : .compact).observation(at: base + 50))
        }
        let journal = await coordinator.journalSnapshot()
        XCTAssertEqual(journal.count, 16)
        XCTAssertGreaterThan(journal.droppedCount, 0)
    }
}
