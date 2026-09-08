# PostureContinuity

**A fold is not a resize. It is a transaction boundary — and most apps roll the user back across it.**

`PostureContinuity` is a Swift package that keeps in-flight user work — a checkout half-filled, a search three screens deep, a composer with the caret in a field — intact across display-posture transitions on foldable and resizable iPhones. It is a generation-ordered capture/restore state machine (`ContinuityCoordinator`), a per-feature layout policy layer (`FeatureLayoutPolicy`, hinge-aware), a width-independent snapshot model (`ScrollAnchor`, `NavigationState` that projects losslessly between stack and split shapes), a bounded observability journal with an independent invariant checker, and a scriptable posture source so an agent can drive the whole thing from a launch argument.

Companion demo app: **[posture-continuity-demo-app](https://github.com/rajatslakhina/posture-continuity-demo-app)** — a separate repository with a real `Demo.xcodeproj` that consumes this package as a remote Swift Package pinned `upToNextMajorVersion` from `1.0.1`.

[![CI](https://github.com/rajatslakhina/posture-continuity-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/rajatslakhina/posture-continuity-kit/actions/workflows/ci.yml)

---

## Why this matters

Rebuilding against the iOS 27 SDK opts an app into resizable-window behaviour. There is no separate "foldable" flag to leave unset; the letterboxing escape hatch is gone; the simulator is resizable; `foldState` / hinge-angle values are in the betas. Android's foldable era produced six years of "giant black bars on my new phone" because adaptation was optional. Apple made it structural, which moves the question from *"does the layout adapt?"* to the one nobody has an answer for yet:

> The user is mid-checkout. They unfold the phone. The view hierarchy rebuilds into two columns. **Where is the caret? Where is the scroll position? Is the address sheet still up? Is the navigation stack — which no longer exists, because two columns have a selection instead — pointing at the same order?**

The naive answers are each wrong in a way that ships:

- **Restore the pixel offset.** 1,240 pt down in one column is a different row once every row reflows. The user lands on the wrong item and does not know why.
- **Snapshot on every geometry change.** The hinge reports a dozen intermediate geometries during one fold. The last one you captured is the transient mid-fold layout, and that is what you restore.
- **Restore whatever arrived last.** Fold, unfold, fold inside a second. Three restores race. The one that applies last was planned from state two transitions old. The user has been rolled back and every field they typed into since is gone.
- **Keep focus wherever it was.** The field was in the two-column editor pane. It does not exist in one column. Focus is now on nothing, and the keyboard is up.

Every one of those is a decision that has to be made *once, in one place, with a test* — not rediscovered per screen by forty engineers on a decade-old codebase. That is the lead-level problem this package is about: not "make this screen adapt" but "define the contract every flow in the app obeys across a fold, and make the contract enforceable."

---

## What it does

```
UIWindowScene.effectiveGeometry / traits / foldState ─┐
scripted launch argument ─────────────────────────────┼──▶ PostureReader ──▶ PostureObservation (dumb numbers)
recorded field session ───────────────────────────────┘                          │
                                                                                 ▼
                                                                       PostureInterpreter
                                                                (one place that decides what a width
                                                                 or a hinge angle *means*)
                                                                                 │
                                                                                 ▼ DisplayPosture
        flows ── checkpoint (settled only) ──▶ ┌─────────────────────────────────────────────┐
        flows ◀── capture request ──────────── │          ContinuityCoordinator (actor)      │ ──▶ PostureJournal
        flows ── capture(snapshot, gen) ─────▶ │  open gen → captures → settle → RestorePlan │ ──▶ ContinuityReport
        flows ◀── RestorePlan(gen) ─────────── │  storm absorbed · revert · implicit · guard  │ ──▶ ContinuityInvariants
        flows ── acknowledgeRestore(gen) ────▶ └─────────────────────────────────────────────┘
                                                                  │
                                                     LayoutPolicyRegistry (per FlowID)
                                                     SnapshotProjector (stack ⇄ split, focus validity)
```

**Lifecycle of one fold**

1. A transitioning observation opens generation *g*. The coordinator returns a `TransitionTicket` naming every registered flow.
2. Each flow answers `capture(snapshot, generation: g)`. A capture for any other generation is rejected as stale; a capture after the transition has settled is rejected as late — it describes the wrong layout.
3. While *g* is open, `checkpoint` is refused (`.transitionInProgress`). The state of record is the last **settled** state, always.
4. A second transitioning observation inside *g* is a **storm**: the target is updated, the generation and the captures are not. The snapshot of record has not moved, so it must not be re-taken.
5. Settle. If the display ended where it began (fold → unfold within the hold), the outcome is `.reverted`: nothing is restored, no live state is touched, and the journal counts it. Otherwise every flow gets a `RestorePlan`: the captured snapshot (or its checkpoint, marked `.captureMissed`; or empty, marked `.noStateOfRecord`), **projected** into the target layout mode, with a provenance and a list of degradations.
6. The flow applies the plan and calls `acknowledgeRestore(flow, generation: g)`. If a newer generation has settled in the meantime the acknowledgement is refused as `.superseded` — applying it would roll the user back. Duplicates are refused. Acknowledgements for generations that never planned anything are refused.
7. A settled posture that arrives with **no** transitioning observation first (resizable-simulator drag, iPad window resize) is an *implicit* transition: it still plans, from checkpoints, and every plan is marked `.noCaptureWindow` so the field metric can tell the two cases apart.

**Per-feature layout policy.** `LayoutMode` is `.singleColumn` or `.twoColumn(sidebarFraction:)` — the decision a feature actually needs, not a size class. Policies are registered per `FlowID`: a product list splits at 600 pt, a checkout form never splits, and `HingeAvoidingPolicy` moves the column boundary onto a vertical hinge (no control straddles the crease) and forces one column across a horizontal one (laptop posture — stacking two panels across a fold is the layout users photograph).

**Width-independent snapshot.** `ScrollAnchor` is an item identity plus a fraction into that item, never a pixel offset; `NavigationState` carries both the stack shape and the selection shape and `SnapshotProjector` converts between them losslessly (`[.list, .detail(x), .editor(x)]` ⇄ `selection: x, stack: [.editor(x)]`); focus is dropped, and *reported* dropped, when the field does not exist in the target mode according to the flow's `FlowDescriptor`.

**Observability.** Every decision is a `PostureEvent` in a bounded `PostureJournal`. `ContinuityReport` turns the log into the numbers a lead would put on a launch dashboard: storms absorbed, degraded-restore rate, stale captures, superseded restores, longest transition. `ContinuityInvariants.validate` re-derives the ordering contract from the log alone, independently of the coordinator — the tests feed it deliberately broken logs and assert that it fails them. Because the journal is bounded, `validate(_:windowed:)` knows when it is looking at a suffix rather than a session and withholds the three judgements a dropped prefix could falsify (settle-without-open, capture-without-open, restore-without-plan) until it has seen enough of the window; ordering violations are always reported.

**Agent-drivable.** `PostureScript.parse("compact,transitioning@200,expanded@600,transitioning@800,book@1200")` and `PostureScript.fromLaunchArguments(CommandLine.arguments)` let a headless harness (Xcode 27's `xcrun mcp-server`, a UI test, a CI job) push the app through any posture sequence deterministically and read the journal back. `ReplayPostureReader` replays a recorded field session exactly.

---

## Design decisions

| Decision | Why | Rejected alternative |
|---|---|---|
| **Generations, not timestamps, order restores.** Every capture and every acknowledgement carries the generation it belongs to; a plan older than the last settled generation is refused. | Fold/unfold storms make three restores race; the one that lands last is not the one that is right. Wall-clock ordering breaks the moment two events share a millisecond or a clock steps. | "Last write wins" on restore. Rolls the user back under a storm, silently. |
| **Never snapshot mid-transition.** Checkpoints are refused while a generation is open; the snapshot of record is always the last settled state; a storm updates the target but keeps the generation. | The hinge reports many transient geometries per fold. Any of them captured as state of record is the wrong layout, restored faithfully. | Capture on every geometry change and debounce. Debouncing chooses *which* transient state to trust; none of them should be. |
| **Revert is a first-class outcome.** A transition that ends where it began restores nothing and touches no live state. | The user folded and unfolded. Their state never went anywhere. Restoring a snapshot over it is a regression with extra steps. | Always plan, always restore. Correct in the settled case, destructive in the storm case. |
| **Scroll position is an anchor, not an offset.** `ScrollAnchor(itemID:offsetWithinItem:)`, with `fromPixelOffset` / `pixelOffset` conversions for legacy views. | Row heights change with width. A pixel offset is meaningful in exactly one layout. | Store `contentOffset`. The most common continuity bug on resizable devices. |
| **Navigation is projected, not preserved.** Stack ⇄ split conversion is a pure function with a round-trip test. | One column has a stack; two columns have a sidebar selection. There is no representation that is "the same" in both — only a mapping. | Keep a `NavigationPath` and hope. `NavigationSplitView` will not read it. |
| **Focus validity is declared, not guessed.** `FlowDescriptor` lists which fields exist per layout mode; projection drops focus that cannot survive and reports `.focusDropped(field:)`. | A field that only exists in the editor pane cannot be focused after a fold. Silently focusing nothing leaves the keyboard up over no field. | Restore focus unconditionally and let SwiftUI ignore it. It does not ignore it cleanly. |
| **Layout policy per feature, not per screen or per app.** `LayoutPolicyRegistry` keyed by `FlowID`, with a hinge-aware wrapper. | Checkout and product list have different split thresholds *for product reasons*. One breakpoint cannot express that; forty screens each deciding cannot be reviewed. | A global `horizontalSizeClass` switch. Every screen special-cases `.regular` within a month. |
| **Degradation is reported, never hidden.** Every plan carries `[Degradation]` and a `SnapshotProvenance`. | A restore from a stale checkpoint and a restore from a fresh capture look identical to the user until they don't. The field metric has to distinguish them. | Best-effort restore with no provenance. Undebuggable in the field. |
| **Actor with no `await` in any method body.** Callers suspend; the coordinator computes. | A suspending actor method interleaves. `read → await → write` in `settle` would let a second fold plan against state the first had replaced. | `async` methods that await a clock or a delegate mid-computation. The classic actor-reentrancy bug. |
| **Invariant checker independent of the coordinator.** `ContinuityInvariants.validate(events)` re-derives the contract from the journal. | A coordinator that validates its own output cannot catch its own bugs. The checker catches what the coordinator prevents, and the tests prove it by feeding it logs the coordinator would never write. | Trust the coordinator. |
| **Every trapping operation guarded, every structure bounded.** `Sanitize.saturatingInt`, clamps on every fraction and angle, `Int64.max` guards on the clock, saturating generation and storm counters, saturating millisecond→nanosecond conversion in the paced reader, `Int.max`-derived ceilings; the journal is a ring, the applied-restore record is one generation per flow rather than a growing set. | A NaN hinge angle from a flaky sensor must not crash a checkout. | Trust the platform's numbers. |

**Adjacent work, stated plainly.** Two earlier packages in this portfolio touch nearby ground: [`adaptive-layout-kit`](https://github.com/rajatslakhina/adaptive-layout-kit) (width breakpoints, a hinge-transition debouncer, a static-analysis scanner for fixed-layout risk) and [`display-class-planner-kit`](https://github.com/rajatslakhina/display-class-planner-kit) (re-planning *in-flight network work* across a display-class change, with hysteresis). Neither has a notion of user-state continuity: no capture/restore, no generation ordering of restores, no navigation projection, no focus validity, no per-feature policy, no journal-derived invariant checker. This package is the piece that was missing between "the layout adapted" and "the user did not lose anything."

---

## Usage

```swift
import PostureContinuity

// 1. Per-feature layout policy, owned by the app.
let registry = LayoutPolicyRegistry(fallback: WidthThresholdPolicy(minimumWidthForTwoColumns: 600))
    .registering(HingeAvoidingPolicy(base: WidthThresholdPolicy()), for: FlowID("catalog"))
    .registering(AlwaysSingleColumnPolicy(), for: FlowID("payment"))

let coordinator = ContinuityCoordinator(configuration: .init(registry: registry))

// 2. Each flow declares which fields exist in each layout mode.
await coordinator.register(FlowDescriptor(
    id: FlowID("checkout"),
    fieldsBySingleColumn: ["email", "address"],
    fieldsByTwoColumn: ["email", "address", "promo-code"]))

// 3. While settled, checkpoint whenever meaningful state changes.
await coordinator.checkpoint(ContinuitySnapshot(
    flow: FlowID("checkout"),
    scroll: ScrollAnchor(itemID: "item-30"),
    focus: FocusTarget(fieldID: "email", caret: 4),
    navigation: NavigationState(stack: [.list, .detail("order-1")]),
    sheets: ["address-picker"],
    draft: ["email": "r@"]))

// 4. Feed observations from your PostureReader (system, scripted, or replayed).
switch await coordinator.ingest(observation) {
case .transitionOpened(let ticket):
    // Fan out: every flow captures its live state for this generation.
    await coordinator.capture(liveSnapshot(), generation: ticket.generation)
case .settle(.settled(let bundle)):
    for plan in bundle.plans {
        apply(plan.snapshot, in: plan.targetMode)      // projected for the new layout
        await coordinator.acknowledgeRestore(plan.flow, generation: plan.generation)
    }
case .settle(.reverted):
    break                                               // nothing to do — by design
default:
    break
}

// 5. Ship the journal.
let report = await coordinator.report()
report.degradedRestoreRate          // 0...1
report.stormsAbsorbed
await coordinator.violations()      // [] — or a bug, named
```

A scripted harness for CI or an agent:

```swift
let script = try PostureScript.parse("compact,transitioning@100,expanded@500,transitioning@700,book@1100").get()
await coordinator.drive(ScriptedPostureReader(script: script))   // or driveCollecting(_:) for a finite script in a test
```

### Add to a project

```swift
.package(url: "https://github.com/rajatslakhina/posture-continuity-kit.git", from: "1.0.1")
```

Products: `PostureContinuity` (core, platform-agnostic, builds and tests on Linux) and `PostureContinuityUI` (SwiftUI demo view, iOS 17+).

---

## Build and test

```sh
swift build -Xswiftc -warnings-as-errors
swift test
```

The core target has no platform dependencies; the whole test suite runs on Linux. `PostureContinuityUI` is gated on `#if canImport(SwiftUI)` (the view additionally on `os(iOS)`) and is built for real by the macOS CI job against `generic/platform=iOS Simulator`.

### What the tests cover

71 tests in three files (plus `Support.swift` fixtures). The ones worth reading:

- `InvariantTests` — **negative controls.** `testWindowedLogSuppressesDroppedPrefixButNotRealViolations` and `testCoordinatorViolationsStayEmptyAfterTheJournalWraps` prove the windowed checker neither invents violations from a dropped prefix nor misses real ones after it. Each test hands `ContinuityInvariants.validate` a log a *broken* coordinator would have produced (a restore applied after a newer generation settled, a duplicate restore, a capture accepted with no transition open, a nested open, a settle without an open, a restore without a plan) and asserts the checker fails it; `testCheckerCatchesWhatTheCoordinatorPrevents` runs the real coordinator, confirms it refused the superseded restore, then appends the event it refused and shows the checker catches it anyway.
- `ConcurrencyTests` — **real racing writers.** 64 tasks acknowledge the same plan (exactly one `.applied`, 63 `.duplicate`); 120 tasks capture with generations 0/1/2 against an open generation 1 (exactly 40 accepted, 80 rejected with the right reason, and the planned snapshot provably came from an accepted one); 200 checkpoints race a 40-transition replay.
- `CoordinatorTests` — the contract: capture beats checkpoint; missed capture falls back and is counted; storm that reverts restores nothing and keeps the checkpoint; storm that ends elsewhere plans from the original captures with duration measured from the first begin; implicit transition is `.noCaptureWindow`, not `.captureMissed`; superseded / duplicate / no-plan / unknown-flow restores refused; projected snapshot becomes the checkpoint for an immediate second fold, but a flow with no state is not promoted to a phantom empty checkpoint.
- `PrimitiveTests` — NaN/infinite geometry, swapped thresholds, the `Double(Int.max)` rounding trap, empty and mismatched scroll inputs, past-the-end offsets, the stack ⇄ split round trip, per-feature policy disagreement on the same posture, the script parser's every rejection path, journal ring behaviour.

---

## Verification

*(Written against the real results after CI reported — see the Actions tab linked above.)*

- **Local:** `rm -rf .build && swift build -Xswiftc -warnings-as-errors` → `Build complete!`, 0 warnings; `swift build --build-tests -Xswiftc -warnings-as-errors` → clean; `swift test` → **71 tests, 0 failures**, on Swift 6.0.3 (aarch64-unknown-linux-gnu).
- **CI, Linux job** (`ubuntu-latest`, `swift:6.0` container): `swift build -Xswiftc -warnings-as-errors`, `swift build --build-tests -Xswiftc -warnings-as-errors`, `swift test` — **passed** on every commit to `main` so far, including the `v1.0.0` (`f8d0dea`) and `v1.0.1` (`c5395ba`) tags. See the [Actions tab](https://github.com/rajatslakhina/posture-continuity-kit/actions/workflows/ci.yml).
- **CI, iOS job** (`macos-15`): `xcodebuild build -scheme PostureContinuityUI -destination 'generic/platform=iOS Simulator'` — **passed** on the same commits. This is the only place the SwiftUI module is compiled; it proves it compiles for the Simulator, nothing more.
- **Independent review:** three rounds by a reviewer with no memory of building the code, before the demo repo was pushed. Round 1 found four real defects (a sheet that blocked the posture controls, a reachable `UInt64` overflow in the paced reader, an unbounded applied-restore set, false invariant violations after the journal wrapped); round 2 found one (`drive(_:)` accumulated outcomes forever on a live reader); round 3 found one (a doc claim that focus and a presented sheet could be restored simultaneously). All are fixed in `v1.0.1`. The round-3 fix was not independently re-reviewed.
- **Ran on a Simulator: no.** This package was produced by an unattended scheduled run in which computer-use access to Xcode and the Simulator was refused three times (`Computer-use access to "Xcode 26.3", "Simulator" can't be approved during a scheduled run`). The iOS CI job proves the SwiftUI module compiles for the Simulator; it does not prove the app launched. No screenshots exist, here or in the demo repo.

---

## License

MIT — see [LICENSE](LICENSE).
