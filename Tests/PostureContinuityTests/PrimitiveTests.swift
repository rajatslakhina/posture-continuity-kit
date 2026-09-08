import XCTest
@testable import PostureContinuity

final class InterpreterTests: XCTestCase {
    let interpreter = PostureInterpreter()

    func testWidthDecidesLayoutClassAtThreshold() {
        XCTAssertEqual(interpreter.interpret(.init(width: 599.9, height: 800)).layoutClass, .compact)
        XCTAssertEqual(interpreter.interpret(.init(width: 600, height: 800)).layoutClass, .expanded)
    }

    func testNaNAndInfiniteGeometryIsSanitisedNotTrapped() {
        let posture = interpreter.interpret(.init(
            width: .nan, height: -.infinity, foldState: .folded, hingeAngleDegrees: .nan))
        XCTAssertEqual(posture.size, Extent(width: 0, height: 0))
        XCTAssertEqual(posture.layoutClass, .compact)
        XCTAssertEqual(posture.phase, .settled, "a NaN angle must not be read as motion")
        XCTAssertEqual(posture.hinge?.angleDegrees, 180, "unreadable angle falls back to flat")
    }

    func testAngleInsideBandMeansTransitioningEvenIfStateSaysFlat() {
        let posture = interpreter.interpret(.init(width: 760, height: 844, foldState: .flat, hingeAngleDegrees: 95))
        XCTAssertEqual(posture.phase, .transitioning)
        XCTAssertNil(posture.hinge, "flat reports no hinge geometry even while the angle moves")
    }

    func testHalfOpenedIsARestingPostureRegardlessOfAngle() {
        let posture = interpreter.interpret(.init(width: 844, height: 760, foldState: .halfOpened, hingeAngleDegrees: 110))
        XCTAssertEqual(posture.phase, .settled)
        XCTAssertEqual(posture.hinge?.axis, .vertical)
        XCTAssertEqual(posture.hinge?.angleDegrees, 110)
    }

    func testTransitioningStateWinsOverAnyAngle() {
        let posture = interpreter.interpret(.init(width: 760, height: 844, foldState: .transitioning, hingeAngleDegrees: 180))
        XCTAssertEqual(posture.phase, .transitioning)
    }

    func testSwappedBandThresholdsAreNormalised() {
        let swapped = PostureInterpreter(foldedBelowDegrees: 160, flatAboveDegrees: 20)
        XCTAssertEqual(swapped.foldedBelowDegrees, 20)
        XCTAssertEqual(swapped.flatAboveDegrees, 160)
        XCTAssertEqual(swapped.interpret(.init(width: 700, height: 800, foldState: .flat, hingeAngleDegrees: 90)).phase, .transitioning)
    }

    func testOutOfRangeAngleIsClampedInHingeGeometry() {
        let hinge = HingeGeometry(axis: .vertical, separatorFraction: 7, angleDegrees: -40)
        XCTAssertEqual(hinge.separatorFraction, 1)
        XCTAssertEqual(hinge.angleDegrees, 0)
    }

    func testEquivalenceIgnoresWidthJitterButNotHingeAxis() {
        var jittered = Fixtures.expanded
        jittered.size = Extent(width: 758, height: 844)
        XCTAssertTrue(Fixtures.expanded.isEquivalent(to: jittered))

        var book = Fixtures.expanded
        book.hinge = HingeGeometry(axis: .vertical, separatorFraction: 0.5, angleDegrees: 120)
        XCTAssertFalse(Fixtures.expanded.isEquivalent(to: book))
        XCTAssertFalse(Fixtures.compact.isEquivalent(to: Fixtures.expanded))
    }
}

final class SanitizeTests: XCTestCase {
    func testSaturatingIntNeverTraps() {
        XCTAssertEqual(Sanitize.saturatingInt(.nan), 0)
        XCTAssertEqual(Sanitize.saturatingInt(.infinity), Int(Double(Int.max).nextDown))
        XCTAssertEqual(Sanitize.saturatingInt(-.infinity), Int.min)
        XCTAssertEqual(Sanitize.saturatingInt(1e300), Int(Double(Int.max).nextDown))
        XCTAssertEqual(Sanitize.saturatingInt(-1e300), Int.min)
        XCTAssertEqual(Sanitize.saturatingInt(42.9), 42)
        XCTAssertEqual(Sanitize.saturatingInt(-42.9), -42)
        // Exactly at the boundary: Double(Int.max) rounds up to 2^63, which is
        // out of range for Int(_:) — the whole reason the ceiling is nextDown.
        XCTAssertEqual(Sanitize.saturatingInt(Double(Int.max)), Int(Double(Int.max).nextDown))
    }

    func testClampHandlesInvertedBoundsAndNaN() {
        XCTAssertEqual(Sanitize.clamp(5, lower: 10, upper: 0), 5)
        XCTAssertEqual(Sanitize.clamp(.nan, lower: 1, upper: 2), 1)
        XCTAssertEqual(Sanitize.clamp(-.infinity, lower: 1, upper: 2), 1)
        XCTAssertEqual(Sanitize.clamp(.infinity, lower: 1, upper: 2), 1, "non-finite resolves to the lower bound")
        XCTAssertEqual(Sanitize.nonNegativeFinite(-3), 0)
    }
}

final class ScrollAnchorTests: XCTestCase {
    let ids = ["a", "b", "c", "d"]
    let oneColumn: [Double] = [100, 100, 100, 100]
    let twoColumn: [Double] = [60, 60, 60, 60]

    func testAnchorSurvivesReflowWherePixelOffsetDoesNot() {
        // 250 pt down in one column is half-way through "c".
        let anchor = ScrollAnchor.fromPixelOffset(250, itemIDs: ids, itemHeights: oneColumn)
        XCTAssertEqual(anchor, ScrollAnchor(itemID: "c", offsetWithinItem: 0.5))

        // In two columns the rows are shorter. The anchor lands on "c" again;
        // the raw pixel offset (250) would have landed inside "e" if it
        // existed — past the end of the list.
        let projected = anchor?.pixelOffset(itemIDs: ids, itemHeights: twoColumn)
        XCTAssertEqual(projected, 150)
        let naive = ScrollAnchor.fromPixelOffset(250, itemIDs: ids, itemHeights: twoColumn)
        XCTAssertEqual(naive?.itemID, "d", "the naive pixel restore shows the wrong row")
    }

    func testDegenerateInputsResolveWithoutTrapping() {
        XCTAssertNil(ScrollAnchor.fromPixelOffset(10, itemIDs: [], itemHeights: []))
        XCTAssertNil(ScrollAnchor.fromPixelOffset(10, itemIDs: ["a"], itemHeights: []))
        XCTAssertEqual(
            ScrollAnchor.fromPixelOffset(10, itemIDs: ["a", "b"], itemHeights: [0, 0]),
            ScrollAnchor(itemID: "b", offsetWithinItem: 0),
            "zero heights: past the end lands on the last item with no division")
        XCTAssertEqual(
            ScrollAnchor.fromPixelOffset(.nan, itemIDs: ids, itemHeights: oneColumn)?.itemID, "a")
        XCTAssertEqual(
            ScrollAnchor.fromPixelOffset(-500, itemIDs: ids, itemHeights: oneColumn)?.itemID, "a")
        XCTAssertEqual(
            ScrollAnchor.fromPixelOffset(.infinity, itemIDs: ids, itemHeights: oneColumn)?.itemID, "a",
            "non-finite offsets sanitise to zero rather than to the end")
        XCTAssertEqual(
            ScrollAnchor.fromPixelOffset(1_000, itemIDs: ids, itemHeights: oneColumn),
            ScrollAnchor(itemID: "d", offsetWithinItem: 1),
            "past the end clamps to the bottom of the last item")
    }

    func testMissingAnchorItemReturnsNilInsteadOfRowZero() {
        let anchor = ScrollAnchor(itemID: "gone", offsetWithinItem: 0.3)
        XCTAssertNil(anchor.pixelOffset(itemIDs: ids, itemHeights: oneColumn))
        XCTAssertNil(anchor.pixelOffset(itemIDs: ids, itemHeights: [1, 2]), "mismatched counts are refused")
    }

    func testOffsetWithinItemIsClamped() {
        XCTAssertEqual(ScrollAnchor(itemID: "a", offsetWithinItem: 4).offsetWithinItem, 1)
        XCTAssertEqual(ScrollAnchor(itemID: "a", offsetWithinItem: .nan).offsetWithinItem, 0)
    }
}

final class ProjectionTests: XCTestCase {
    let split = LayoutMode.split(0.4)

    func testStackBecomesSelectionInTwoColumns() {
        let stack = NavigationState(stack: [.list, .detail("o1"), .editor("o1")])
        let projected = SnapshotProjector.projectNavigation(stack, from: .singleColumn, to: split)
        XCTAssertEqual(projected, NavigationState(stack: [.editor("o1")], selection: "o1"))
    }

    func testSelectionBecomesPushedDetailInOneColumn() {
        let splitState = NavigationState(stack: [.editor("o1")], selection: "o1")
        let projected = SnapshotProjector.projectNavigation(splitState, from: split, to: .singleColumn)
        XCTAssertEqual(projected, NavigationState(stack: [.list, .detail("o1"), .editor("o1")], selection: nil))
    }

    func testRoundTripIsLossless() {
        let original = NavigationState(stack: [.list, .detail("o1"), .editor("o1")])
        let there = SnapshotProjector.projectNavigation(original, from: .singleColumn, to: split)
        let back = SnapshotProjector.projectNavigation(there, from: split, to: .singleColumn)
        XCTAssertEqual(back, original)
    }

    func testSameModeIsIdentity() {
        let state = NavigationState(stack: [.list], selection: nil)
        XCTAssertEqual(SnapshotProjector.projectNavigation(state, from: .singleColumn, to: .singleColumn), state)
        XCTAssertEqual(SnapshotProjector.projectNavigation(state, from: split, to: .split(0.6)), state)
    }

    func testListOnlyStackDoesNotGrowASecondList() {
        let alreadyStack = NavigationState(stack: [.list], selection: nil)
        let projected = SnapshotProjector.projectNavigation(alreadyStack, from: split, to: .singleColumn)
        XCTAssertEqual(projected, alreadyStack)
        let noSelection = NavigationState(stack: [], selection: nil)
        XCTAssertEqual(
            SnapshotProjector.projectNavigation(noSelection, from: split, to: .singleColumn),
            NavigationState(stack: [.list], selection: nil))
    }

    func testFocusIsDroppedWhenFieldDoesNotExistInTargetMode() {
        let snapshot = Fixtures.checkoutSnapshot(focus: "promo-code")
        let result = SnapshotProjector.project(
            snapshot, from: split, to: .singleColumn, descriptor: Fixtures.checkoutDescriptor)
        XCTAssertNil(result.snapshot.focus)
        XCTAssertEqual(result.degradations, [.focusDropped(field: "promo-code")])
        XCTAssertEqual(result.snapshot.draft, snapshot.draft, "draft survives the fold untouched")
        XCTAssertEqual(result.snapshot.sheets, snapshot.sheets)
    }

    func testFocusIsKeptWhenFieldExistsEverywhere() {
        let snapshot = Fixtures.checkoutSnapshot(focus: "email")
        let result = SnapshotProjector.project(
            snapshot, from: split, to: .singleColumn, descriptor: Fixtures.checkoutDescriptor)
        XCTAssertEqual(result.snapshot.focus?.fieldID, "email")
        XCTAssertTrue(result.degradations.isEmpty)
    }

    func testFocusCaretNeverNegative() {
        XCTAssertEqual(FocusTarget(fieldID: "f", caret: -9).caret, 0)
    }
}

final class LayoutPolicyTests: XCTestCase {
    func testWidthThresholdRequiresExpandedClassAndWidth() {
        let policy = WidthThresholdPolicy(minimumWidthForTwoColumns: 900, sidebarFraction: 0.3)
        XCTAssertEqual(policy.resolve(Fixtures.compact), .singleColumn)
        XCTAssertEqual(policy.resolve(Fixtures.expanded), .singleColumn, "expanded class but under this feature's own threshold")
        var wide = Fixtures.expanded
        wide.size = Extent(width: 900, height: 844)
        XCTAssertEqual(policy.resolve(wide), .split(0.3))
    }

    func testHingeAvoidingMovesBoundaryOntoVerticalHinge() {
        var book = Fixtures.expanded
        book.hinge = HingeGeometry(axis: .vertical, separatorFraction: 0.52, angleDegrees: 120)
        let policy = HingeAvoidingPolicy(base: WidthThresholdPolicy(sidebarFraction: 0.3))
        XCTAssertEqual(policy.resolve(book), .split(0.52))
    }

    func testHingeAvoidingForcesSingleColumnAcrossHorizontalHinge() {
        var laptop = Fixtures.expanded
        laptop.hinge = HingeGeometry(axis: .horizontal, separatorFraction: 0.5, angleDegrees: 110)
        let policy = HingeAvoidingPolicy(base: WidthThresholdPolicy())
        XCTAssertEqual(policy.resolve(laptop), .singleColumn)
        XCTAssertEqual(policy.resolve(Fixtures.expanded), .split(0.38), "no hinge: base policy is untouched")
    }

    func testHingeAvoidingDoesNotInventAColumnTheBaseRefused() {
        var book = Fixtures.expanded
        book.hinge = HingeGeometry(axis: .vertical, separatorFraction: 0.5, angleDegrees: 120)
        let policy = HingeAvoidingPolicy(base: AlwaysSingleColumnPolicy())
        XCTAssertEqual(policy.resolve(book), .singleColumn)
    }

    func testRegistryResolvesPerFeatureWithFallback() {
        let registry = LayoutPolicyRegistry(fallback: WidthThresholdPolicy(sidebarFraction: 0.5))
            .registering(AlwaysSingleColumnPolicy(), for: Fixtures.checkout)
        XCTAssertEqual(registry.resolve(Fixtures.checkout, in: Fixtures.expanded), .singleColumn)
        XCTAssertEqual(registry.resolve(Fixtures.search, in: Fixtures.expanded), .split(0.5))
        XCTAssertEqual(registry.registeredFlows, [Fixtures.checkout])
    }

    func testSplitFractionIsSanitised() {
        XCTAssertEqual(LayoutMode.split(.nan), .twoColumn(sidebarFraction: 0))
        XCTAssertEqual(LayoutMode.split(3), .twoColumn(sidebarFraction: 1))
    }
}

final class ScriptTests: XCTestCase {
    func testParsesKeywordsWithAndWithoutTimes() throws {
        let script = try PostureScript.parse("compact, transitioning@200 , expanded@600ms,book", defaultGapMillis: 100).get()
        XCTAssertEqual(script.steps.map(\.keyword), [.compact, .transitioning, .expanded, .book])
        XCTAssertEqual(script.steps.map(\.atMillis), [0, 200, 600, 700])
    }

    func testRejectsUnknownKeywordAndBadTimeWithoutTrapping() {
        XCTAssertEqual(PostureScript.parse("compact,sideways"), .failure(.unknownKeyword("sideways")))
        XCTAssertEqual(PostureScript.parse("compact@soon"), .failure(.invalidTime("soon")))
        XCTAssertEqual(PostureScript.parse("compact@-5"), .failure(.invalidTime("-5")))
        XCTAssertEqual(PostureScript.parse("compact@99999999999999999999"), .failure(.invalidTime("99999999999999999999")))
        XCTAssertEqual(PostureScript.parse(" , ,"), .failure(.empty))
        XCTAssertEqual(PostureScript.parse("@5"), .failure(.unknownKeyword("")))
    }

    func testGapSaturatesNearInt64Max() throws {
        let script = try PostureScript.parse("compact@\(Int64.max - 1),expanded", defaultGapMillis: 500).get()
        XCTAssertEqual(script.steps.last?.atMillis, Int64.max)
    }

    func testLaunchArgumentsAbsentReturnsNil() {
        XCTAssertNil(PostureScript.fromLaunchArguments(["Demo"]))
        XCTAssertEqual(PostureScript.fromLaunchArguments(["Demo", "-posture-script"]), .failure(.empty))
        XCTAssertEqual(
            PostureScript.fromLaunchArguments(["Demo", "-posture-script", "compact,expanded@10"])?.map { $0.steps.count },
            .success(2))
    }

    func testKeywordObservationsInterpretAsIntended() {
        let interpreter = PostureInterpreter()
        XCTAssertEqual(interpreter.interpret(PostureKeyword.compact.observation(at: 0)).layoutClass, .compact)
        XCTAssertEqual(interpreter.interpret(PostureKeyword.expanded.observation(at: 0)).layoutClass, .expanded)
        XCTAssertEqual(interpreter.interpret(PostureKeyword.transitioning.observation(at: 0)).phase, .transitioning)
        XCTAssertEqual(interpreter.interpret(PostureKeyword.halfOpened.observation(at: 0)).hinge?.axis, .horizontal)
        XCTAssertEqual(interpreter.interpret(PostureKeyword.book.observation(at: 0)).hinge?.axis, .vertical)
    }
}

final class JournalTests: XCTestCase {
    func testCapacityIsClampedAndOldestEntriesDrop() {
        var journal = PostureJournal(capacity: 0)
        XCTAssertEqual(journal.capacity, 1)
        journal.append(.checkpointAccepted(flow: Fixtures.checkout))
        journal.append(.checkpointAccepted(flow: Fixtures.search))
        XCTAssertEqual(journal.count, 1)
        XCTAssertEqual(journal.droppedCount, 1)
        XCTAssertEqual(journal.events, [.checkpointAccepted(flow: Fixtures.search)])
        XCTAssertEqual(journal.report().droppedEvents, 1)
    }

    func testReportCountsDegradationsByKindAndRate() {
        var journal = PostureJournal()
        journal.append(.restorePlanned(Generation(1), flow: Fixtures.checkout, degradations: [.captureMissed, .focusDropped(field: "x")]))
        journal.append(.restorePlanned(Generation(1), flow: Fixtures.search, degradations: []))
        journal.append(.transitionSettled(Generation(1), posture: Fixtures.expanded, at: 900, durationMillis: 400))
        journal.append(.transitionSettled(Generation(2), posture: Fixtures.compact, at: 2000, durationMillis: 150))
        let report = journal.report()
        XCTAssertEqual(report.restoresPlanned, 2)
        XCTAssertEqual(report.restoresDegraded, 1)
        XCTAssertEqual(report.degradedRestoreRate, 0.5)
        XCTAssertEqual(report.degradationsByKind, ["captureMissed": 1, "focusDropped": 1])
        XCTAssertEqual(report.maxTransitionMillis, 400)
        XCTAssertEqual(ContinuityReport().degradedRestoreRate, 0, "no plans: no division")
    }

    func testGenerationNextSaturates() {
        XCTAssertEqual(Generation(UInt64.max).next(), Generation(UInt64.max))
        XCTAssertEqual(Generation(3).next(), Generation(4))
        XCTAssertTrue(Generation(3) < Generation(4))
    }
}
