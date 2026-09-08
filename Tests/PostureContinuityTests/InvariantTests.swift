import XCTest
@testable import PostureContinuity

/// Negative controls. Each test hands the checker a log a *broken*
/// coordinator would have produced and asserts the checker fails it. A
/// checker that passes every one of these is not checking anything.
final class InvariantTests: XCTestCase {
    let g1 = Generation(1)
    let g2 = Generation(2)
    let flow = Fixtures.checkout

    private var cleanTwoFolds: [PostureEvent] {
        [
            .baselineSettled(Fixtures.compact, at: 0),
            .transitionOpened(g1, from: Fixtures.compact, toward: Fixtures.moving, at: 100),
            .captureAccepted(g1, flow: flow),
            .transitionSettled(g1, posture: Fixtures.expanded, at: 400, durationMillis: 300),
            .restorePlanned(g1, flow: flow, degradations: []),
            .restoreApplied(g1, flow: flow),
            .transitionOpened(g2, from: Fixtures.expanded, toward: Fixtures.moving, at: 500),
            .transitionSettled(g2, posture: Fixtures.compact, at: 800, durationMillis: 300),
            .restorePlanned(g2, flow: flow, degradations: []),
            .restoreApplied(g2, flow: flow)
        ]
    }

    func testPositiveControlCleanLogHasNoViolations() {
        XCTAssertEqual(ContinuityInvariants.validate(cleanTwoFolds), [])
        XCTAssertEqual(ContinuityInvariants.validate([]), [])
    }

    func testRestoreAppliedAfterSupersessionIsCaught() {
        // The g1 restore lands after g2 has settled: the flow just rolled back.
        var events = cleanTwoFolds
        events.append(.restoreApplied(g1, flow: Fixtures.search))
        events.insert(.restorePlanned(g1, flow: Fixtures.search, degradations: []), at: 4)
        XCTAssertEqual(
            ContinuityInvariants.validate(events),
            [.restoreAfterSupersession(applied: g1, currentSettled: g2, flow: Fixtures.search)])
    }

    func testDuplicateRestoreIsCaught() {
        var events = cleanTwoFolds
        events.append(.restoreApplied(g2, flow: flow))
        XCTAssertEqual(ContinuityInvariants.validate(events), [.duplicateRestore(g2, flow: flow)])
    }

    func testCaptureOutsideTransitionIsCaught() {
        let events: [PostureEvent] = [
            .baselineSettled(Fixtures.compact, at: 0),
            .captureAccepted(g1, flow: flow)
        ]
        XCTAssertEqual(ContinuityInvariants.validate(events), [.captureOutsideTransition(g1, flow: flow)])
    }

    func testCaptureForTheWrongOpenGenerationIsCaught() {
        let events: [PostureEvent] = [
            .baselineSettled(Fixtures.compact, at: 0),
            .transitionOpened(g2, from: Fixtures.compact, toward: Fixtures.moving, at: 100),
            .captureAccepted(g1, flow: flow)
        ]
        XCTAssertEqual(ContinuityInvariants.validate(events), [.captureOutsideTransition(g1, flow: flow)])
    }

    func testNestedOpenIsCaught() {
        let events: [PostureEvent] = [
            .baselineSettled(Fixtures.compact, at: 0),
            .transitionOpened(g1, from: Fixtures.compact, toward: Fixtures.moving, at: 100),
            .transitionOpened(g2, from: Fixtures.compact, toward: Fixtures.moving, at: 120)
        ]
        XCTAssertEqual(ContinuityInvariants.validate(events), [.nestedTransitionOpened(g2)])
    }

    func testSettleAndRevertWithoutOpenAreCaught() {
        let settled: [PostureEvent] = [
            .transitionSettled(g1, posture: Fixtures.expanded, at: 400, durationMillis: 0)
        ]
        XCTAssertEqual(ContinuityInvariants.validate(settled), [.settleWithoutOpen(g1)])
        let reverted: [PostureEvent] = [.transitionReverted(g1, at: 300, storms: 0)]
        XCTAssertEqual(ContinuityInvariants.validate(reverted), [.settleWithoutOpen(g1)])
    }

    func testRestoreWithoutPlanIsCaught() {
        let events: [PostureEvent] = [
            .baselineSettled(Fixtures.compact, at: 0),
            .transitionOpened(g1, from: Fixtures.compact, toward: Fixtures.moving, at: 100),
            .transitionSettled(g1, posture: Fixtures.expanded, at: 400, durationMillis: 300),
            .restoreApplied(g1, flow: flow)
        ]
        XCTAssertEqual(ContinuityInvariants.validate(events), [.restoreWithoutPlan(g1, flow: flow)])
    }

    func testImplicitTransitionSupersedesOlderRestores() {
        let events: [PostureEvent] = [
            .baselineSettled(Fixtures.compact, at: 0),
            .transitionOpened(g1, from: Fixtures.compact, toward: Fixtures.moving, at: 100),
            .transitionSettled(g1, posture: Fixtures.expanded, at: 400, durationMillis: 300),
            .restorePlanned(g1, flow: flow, degradations: []),
            .implicitTransition(g2, from: Fixtures.expanded, to: Fixtures.compact, at: 450),
            .restoreApplied(g1, flow: flow)
        ]
        XCTAssertEqual(
            ContinuityInvariants.validate(events),
            [.restoreAfterSupersession(applied: g1, currentSettled: g2, flow: flow)])
    }

    /// The real coordinator's journal, plus one event it would never write.
    /// Proves the checker is independent of the coordinator: the coordinator
    /// *refuses* a superseded restore, but if a caller applied one anyway
    /// and logged it, the checker would still notice.
    func testCheckerCatchesWhatTheCoordinatorPrevents() async {
        let coordinator = await Fixtures.coordinator()
        await coordinator.ingest(PostureKeyword.compact.observation(at: 0))
        await coordinator.checkpoint(Fixtures.checkoutSnapshot())
        await coordinator.ingest(PostureKeyword.transitioning.observation(at: 100))
        await coordinator.ingest(PostureKeyword.expanded.observation(at: 400))
        await coordinator.ingest(PostureKeyword.transitioning.observation(at: 500))
        await coordinator.ingest(PostureKeyword.compact.observation(at: 800))
        let refused = await coordinator.acknowledgeRestore(Fixtures.checkout, generation: Generation(1))
        XCTAssertEqual(refused, .rejected(.superseded(planned: Generation(1), current: Generation(2))))

        var events = await coordinator.journalSnapshot().events
        XCTAssertEqual(ContinuityInvariants.validate(events), [], "positive control: the real journal is clean")
        events.append(.restoreApplied(Generation(1), flow: Fixtures.checkout))
        XCTAssertEqual(
            ContinuityInvariants.validate(events),
            [.restoreAfterSupersession(applied: Generation(1), currentSettled: Generation(2), flow: Fixtures.checkout)])
    }

    func testViolationDescriptionsAreReadable() {
        let violation = ContinuityInvariants.Violation.restoreAfterSupersession(applied: g1, currentSettled: g2, flow: flow)
        XCTAssertEqual(violation.description, "restore g1 applied for checkout after g2 settled")
        XCTAssertEqual(ContinuityInvariants.Violation.duplicateRestore(g2, flow: flow).description, "duplicate restore g2 for checkout")
    }
}

/// Real concurrent writers against the actor. These would be vacuous with a
/// single caller; the point is that many callers racing on the same
/// generation get exactly the verdicts the contract promises.
final class ConcurrencyTests: XCTestCase {
    func testOnlyOneOfManyRacingRestoresIsApplied() async {
        let coordinator = await Fixtures.coordinator()
        await coordinator.ingest(PostureKeyword.compact.observation(at: 0))
        await coordinator.checkpoint(Fixtures.checkoutSnapshot())
        await coordinator.ingest(PostureKeyword.transitioning.observation(at: 100))
        await coordinator.ingest(PostureKeyword.expanded.observation(at: 400))

        let verdicts = await withTaskGroup(of: RestoreVerdict.self, returning: [RestoreVerdict].self) { group in
            for _ in 0..<64 {
                group.addTask { await coordinator.acknowledgeRestore(Fixtures.checkout, generation: Generation(1)) }
            }
            var collected: [RestoreVerdict] = []
            for await verdict in group { collected.append(verdict) }
            return collected
        }
        XCTAssertEqual(verdicts.filter { $0 == .applied }.count, 1)
        XCTAssertEqual(verdicts.filter { $0 == .rejected(.duplicate) }.count, 63)
        let violations = await coordinator.violations()
        XCTAssertEqual(violations, [])
    }

    func testRacingCapturesWithMixedGenerationsAreSortedExactly() async {
        let coordinator = await Fixtures.coordinator()
        await coordinator.ingest(PostureKeyword.compact.observation(at: 0))
        await coordinator.ingest(PostureKeyword.transitioning.observation(at: 100))

        let verdicts = await withTaskGroup(of: CaptureVerdict.self, returning: [CaptureVerdict].self) { group in
            for i in 0..<120 {
                let generation = Generation(UInt64(i % 3)) // 0 stale, 1 current, 2 "future"
                var snapshot = Fixtures.checkoutSnapshot()
                snapshot.scroll = ScrollAnchor(itemID: "item-\(i)")
                group.addTask { await coordinator.capture(snapshot, generation: generation) }
            }
            var collected: [CaptureVerdict] = []
            for await verdict in group { collected.append(verdict) }
            return collected
        }
        XCTAssertEqual(verdicts.filter { $0 == .accepted(Generation(1)) }.count, 40)
        XCTAssertEqual(verdicts.filter { $0 == .rejected(.stale(offered: Generation(0), current: Generation(1))) }.count, 40)
        XCTAssertEqual(verdicts.filter { $0 == .rejected(.stale(offered: Generation(2), current: Generation(1))) }.count, 40)

        // Whichever accepted capture landed last is the one planned — and it
        // is one of the accepted ones, never a rejected one.
        let plan = await coordinator.ingest(PostureKeyword.expanded.observation(at: 400)).settleOutcome?.bundle?.plan(for: Fixtures.checkout)
        let itemID = plan?.snapshot.scroll?.itemID ?? ""
        let index = Int(itemID.dropFirst("item-".count)) ?? -1
        XCTAssertGreaterThanOrEqual(index, 0)
        XCTAssertEqual(index % 3, 1, "the planned snapshot came from a generation-1 capture")
        let violations = await coordinator.violations()
        XCTAssertEqual(violations, [])
    }

    func testInterleavedIngestAndCheckpointNeverCorruptsTheStateOfRecord() async {
        let coordinator = await Fixtures.coordinator()
        await coordinator.ingest(PostureKeyword.compact.observation(at: 0))
        await coordinator.checkpoint(Fixtures.checkoutSnapshot())

        // One writer folds and unfolds; many writers checkpoint at random
        // moments. Checkpoints that land during a transition must be refused,
        // and every accepted one must describe a settled layout.
        let script = (0..<40).flatMap { i -> [PostureObservation] in
            let base = Int64(i) * 100
            return [
                PostureKeyword.transitioning.observation(at: base + 10),
                (i % 2 == 0 ? PostureKeyword.expanded : PostureKeyword.compact).observation(at: base + 50)
            ]
        }
        async let driving: [IngestOutcome] = coordinator.drive(ReplayPostureReader(script))
        let verdicts = await withTaskGroup(of: CheckpointVerdict.self, returning: [CheckpointVerdict].self) { group in
            for i in 0..<200 {
                var snapshot = Fixtures.checkoutSnapshot()
                snapshot.scroll = ScrollAnchor(itemID: "cp-\(i)")
                group.addTask { await coordinator.checkpoint(snapshot) }
            }
            var collected: [CheckpointVerdict] = []
            for await verdict in group { collected.append(verdict) }
            return collected
        }
        _ = await driving

        let accepted = verdicts.filter { $0 == .accepted }.count
        let refused = verdicts.filter { $0 == .rejected(.transitionInProgress) }.count
        XCTAssertEqual(accepted + refused, 200, "every checkpoint got exactly one of the two settled/transitioning verdicts")
        let report = await coordinator.report()
        XCTAssertEqual(report.checkpointsRejected, refused)
        let violations = await coordinator.violations()
        XCTAssertEqual(violations, [])
        let generation = await coordinator.settledGeneration
        XCTAssertEqual(generation, Generation(40))
    }
}
