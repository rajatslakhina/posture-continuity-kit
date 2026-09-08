#if canImport(SwiftUI) && os(iOS)
import SwiftUI
import PostureContinuity

/// The demo. A checkout flow rendered in one or two columns according to the
/// layout policy the *app* registered, driven through folds by the buttons
/// at the top, with the coordinator's journal and metrics on a second tab.
///
/// The interesting interaction: scroll to item 30, put the caret in the
/// e-mail field, then tap **Unfold**. With restore on, you land in two
/// columns at item 30 with the caret still in the field. With restore off,
/// the layout changes and both are gone. Navigation and the sheet are
/// separate claims, because in one column each of them covers the list (a
/// pushed detail hides the e-mail row; a presented sheet takes first
/// responder from it): open an order, tap Unfold, and the pushed detail
/// becomes the sidebar selection; open the address sheet, tap Unfold through
/// it, and the sheet is re-presented over the new layout.
public struct PostureContinuityDemoView: View {
    @StateObject private var model: PostureContinuitySimulation
    @State private var scriptText: String
    @State private var selectedTab = 0
    @FocusState private var focus: String?

    /// - Parameters:
    ///   - registry: per-feature layout policies, owned by the app.
    ///   - launchScript: a script to auto-run on appear (agent harness).
    public init(registry: LayoutPolicyRegistry, launchScript: PostureScript? = nil) {
        _model = StateObject(wrappedValue: PostureContinuitySimulation(registry: registry))
        _scriptText = State(initialValue: launchScript.map(Self.render) ?? "transitioning@100,expanded@600,transitioning@800,book@1200,transitioning@1400,compact@1900")
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            flowScreen
                .tabItem { Label("Flow", systemImage: "rectangle.split.2x1") }
                .tag(0)

            NavigationStack {
                journalScreen
                    .navigationTitle("Journal")
            }
            .tabItem { Label("Journal", systemImage: "list.bullet.rectangle") }
            .tag(1)
        }
        .task { await model.start(); await autoRunIfScripted() }
        .onChange(of: focus) { _, newValue in model.focusedField = newValue }
        .onChange(of: model.focusedField) { _, newValue in focus = newValue }
        .sheet(isPresented: $model.sheetPresented) { addressSheet }
    }

    // MARK: Flow tab

    private var flowScreen: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            postureStrip
            Divider()
            ZStack {
                content
                    .frame(maxWidth: contentWidth)
                    .frame(maxWidth: .infinity)
                if model.phase == .transitioning {
                    transitioningOverlay
                }
            }
            Divider()
            outcomeStrip
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                postureButton("Fold", .compact, system: "iphone")
                postureButton("Unfold", .expanded, system: "ipad")
                postureButton("Book", .book, system: "book")
                postureButton("Laptop", .halfOpened, system: "laptopcomputer")
            }
            HStack(spacing: 8) {
                Button {
                    Task { await model.storm(returningTo: currentKeyword) }
                } label: { Label("Storm", systemImage: "wind") }
                Button {
                    Task { await model.jump(to: model.layoutMode.isTwoColumn ? .compact : .expanded) }
                } label: { Label("Jump", systemImage: "arrow.left.arrow.right") }
                Button {
                    Task { await model.checkpointNow() }
                } label: { Label("Checkpoint", systemImage: "flag") }
                Toggle("Restore", isOn: $model.restoreEnabled)
                    .toggleStyle(.button)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isBusy)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func postureButton(_ title: String, _ keyword: PostureKeyword, system: String) -> some View {
        Button {
            Task { await model.move(to: keyword) }
        } label: { Label(title, systemImage: system) }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(model.isBusy)
    }

    private var postureStrip: some View {
        HStack {
            Text(model.posture.map { model.describe($0) } ?? "no posture yet")
                .font(.caption.monospaced())
            Spacer()
            Text(model.modeDescription)
                .font(.caption.bold())
            Text(model.phase == .transitioning ? "transitioning" : "settled")
                .font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(model.phase == .transitioning ? Color.orange.opacity(0.25) : Color.green.opacity(0.2))
                .clipShape(Capsule())
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var transitioningOverlay: some View {
        VStack(spacing: 6) {
            ProgressView()
            Text("Hinge moving — state frozen, capture taken")
                .font(.caption)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var outcomeStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.lastOutcome)
                .font(.caption.monospaced())
                .lineLimit(3)
            if let plan = model.lastPlan {
                Text("plan \(plan.generation): \(describe(plan.sourceMode)) → \(describe(plan.targetMode)) · scroll \(plan.snapshot.scroll?.itemID ?? "—") · focus \(plan.snapshot.focus?.fieldID ?? "—") · nav \(describe(plan.snapshot.navigation))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.layoutMode {
        case .singleColumn:
            singleColumn
        case .twoColumn(let fraction):
            twoColumns(sidebarFraction: fraction)
        }
    }

    /// Stack shape: the list is the root; a detail is pushed on top of it.
    private var singleColumn: some View {
        NavigationStack(path: pushedPath) {
            orderList
                .navigationTitle("Checkout")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: NavigationRoute.self) { route in
                    detailPane(for: route)
                }
        }
    }

    /// Split shape: hand-rolled rather than `NavigationSplitView` so the
    /// sidebar fraction — which the hinge-aware policy sets to the crease —
    /// is visibly honoured.
    private func twoColumns(sidebarFraction: Double) -> some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width)
            let sidebar = width * Sanitize.unitFraction(sidebarFraction)
            HStack(spacing: 0) {
                orderList
                    .frame(width: sidebar)
                Divider()
                Group {
                    if let selection = model.navigation.selection {
                        detailPane(for: .detail(selection))
                    } else {
                        ContentUnavailableView("Select an order", systemImage: "cart")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var orderList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                emailRow
                ForEach(model.items, id: \.self) { item in
                    Button {
                        select(item)
                    } label: {
                        HStack {
                            Image(systemName: "shippingbox")
                            Text(item)
                            Spacer()
                            if isSelected(item) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .id(item)
                    Divider()
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $model.topItemID)
    }

    private var emailRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Receipt e-mail").font(.caption).foregroundStyle(.secondary)
            TextField("you@example.com", text: $model.draftEmail)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: PostureContinuitySimulation.emailField)
                .autocorrectionDisabled()
            Button("Choose address…") { model.sheetPresented = true }
                .font(.caption)
        }
        .padding()
        .id("email-row")
    }

    private func detailPane(for route: NavigationRoute) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch route {
            case .list:
                Text("List")
            case .detail(let id):
                Text(id).font(.title2.bold())
                Text("Order detail. In two columns this pane has a promo-code field the one-column layout does not, so focus here is dropped on a fold — and the plan says so.")
                    .font(.footnote).foregroundStyle(.secondary)
                if model.layoutMode.isTwoColumn {
                    TextField("Promo code", text: .constant(""))
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: PostureContinuitySimulation.promoField)
                }
            case .editor(let id):
                Text("Editing \(id)")
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Order")
    }

    private var addressSheet: some View {
        NavigationStack {
            List(["Home", "Office", "Parents"], id: \.self) { Text($0) }
                .navigationTitle("Address")
                .toolbar { Button("Done") { model.sheetPresented = false } }
        }
        .presentationDetents([.medium])
        // The posture controls sit above the sheet; without this a medium
        // sheet blocks them and "open the sheet, then Unfold" is impossible.
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    // MARK: Journal tab

    private var journalScreen: some View {
        List {
            Section("Metrics") {
                metric("Transitions opened", model.report.transitionsOpened)
                metric("Settled", model.report.transitionsSettled)
                metric("Reverted", model.report.transitionsReverted)
                metric("Implicit (no capture window)", model.report.implicitTransitions)
                metric("Storms absorbed", model.report.stormsAbsorbed)
                metric("Captures accepted / rejected", "\(model.report.capturesAccepted) / \(model.report.capturesRejected)")
                metric("Checkpoints rejected mid-transition", model.report.checkpointsRejected)
                metric("Restores planned / degraded", "\(model.report.restoresPlanned) / \(model.report.restoresDegraded)")
                metric("Restores applied / rejected", "\(model.report.restoresApplied) / \(model.report.restoresRejected)")
                metric("Longest transition (ms)", Int(clamping: model.report.maxTransitionMillis))
                metric("Invariant violations", model.violations.count)
            }
            Section("Script") {
                TextField("compact,transitioning@200,expanded@600", text: $scriptText)
                    .font(.caption.monospaced())
                    .autocorrectionDisabled()
                Button("Run script") { Task { await model.run(scriptText: scriptText) } }
                    .disabled(model.isBusy)
            }
            Section("Events (newest first)") {
                ForEach(model.log) { line in
                    Text(line.text).font(.caption.monospaced())
                }
            }
        }
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        metric(title, String(value))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    // MARK: Helpers

    private var contentWidth: CGFloat {
        guard let width = model.posture?.size.width, width > 0 else { return .infinity }
        return CGFloat(width)
    }

    private var currentKeyword: PostureKeyword {
        guard let posture = model.posture else { return .compact }
        if posture.layoutClass == .compact { return .compact }
        switch posture.hinge?.axis {
        case .vertical?: return .book
        case .horizontal?: return .halfOpened
        case nil: return .expanded
        }
    }

    /// The pushed part of the single-column stack: everything after `.list`.
    private var pushedPath: Binding<[NavigationRoute]> {
        Binding(
            get: {
                var stack = model.navigation.stack
                if stack.first == .list { stack.removeFirst() }
                return stack
            },
            set: { pushed in
                model.navigation = NavigationState(stack: [.list] + pushed, selection: nil)
            })
    }

    private func select(_ item: String) {
        if model.layoutMode.isTwoColumn {
            model.navigation = NavigationState(stack: [], selection: item)
        } else {
            model.navigation = NavigationState(stack: [.list, .detail(item)], selection: nil)
        }
    }

    private func isSelected(_ item: String) -> Bool {
        if model.navigation.selection == item { return true }
        return model.navigation.stack.contains(.detail(item))
    }

    private func autoRunIfScripted() async {
        guard let script = PostureScript.fromLaunchArguments(CommandLine.arguments) else { return }
        if case .success(let parsed) = script {
            await model.run(scriptText: Self.render(parsed))
        }
    }

    private static func render(_ script: PostureScript) -> String {
        script.steps.map { "\($0.keyword.rawValue)@\($0.atMillis)" }.joined(separator: ",")
    }

    private func describe(_ mode: LayoutMode) -> String {
        switch mode {
        case .singleColumn: return "1col"
        case .twoColumn(let fraction): return "2col@\(Sanitize.saturatingInt(fraction * 100))%"
        }
    }

    private func describe(_ navigation: NavigationState) -> String {
        let stack = navigation.stack.map { route -> String in
            switch route {
            case .list: return "list"
            case .detail(let id): return "detail(\(id))"
            case .editor(let id): return "editor(\(id))"
            }
        }.joined(separator: ">")
        return navigation.selection.map { "sel:\($0)" } ?? (stack.isEmpty ? "—" : stack)
    }
}
#endif
