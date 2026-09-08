import Foundation

// MARK: - Reader protocol

/// The seam between the platform and the coordinator. The system conformance
/// lives in the app (it needs `UIWindowScene`); the library ships the
/// simulated and replay conformances, which is what makes fold behaviour
/// testable on Linux CI and drivable by an agent through launch arguments.
public protocol PostureReader: Sendable {
    func observations() -> AsyncStream<PostureObservation>
}

/// Replays a recorded sequence exactly, in order, without delay. Feed it the
/// observations that preceded a field bug and the coordinator will walk the
/// same path.
public struct ReplayPostureReader: PostureReader {
    public var recorded: [PostureObservation]

    public init(_ recorded: [PostureObservation]) {
        self.recorded = recorded
    }

    public func observations() -> AsyncStream<PostureObservation> {
        let recorded = self.recorded
        return AsyncStream { continuation in
            for observation in recorded { continuation.yield(observation) }
            continuation.finish()
        }
    }
}

// MARK: - Script

/// A posture keyword the script language understands. Sizes are the ones the
/// demo uses; a team would substitute its own device table.
public enum PostureKeyword: String, Sendable, Hashable, CaseIterable {
    case compact
    case expanded
    case transitioning
    /// Laptop posture: unfolded, hinge horizontal. Expanded width, but a
    /// hinge-aware policy refuses to stack panels across the crease.
    case halfOpened
    /// Book posture: unfolded in landscape, hinge vertical. The one posture
    /// where a hinge-aware policy moves the column boundary onto the crease.
    case book
    case folded

    public func observation(at millis: Int64) -> PostureObservation {
        switch self {
        case .compact:
            return PostureObservation(width: 390, height: 844, foldState: .folded, hingeAngleDegrees: 0, timestampMillis: millis)
        case .folded:
            return PostureObservation(width: 390, height: 844, foldState: .folded, hingeAngleDegrees: 0, timestampMillis: millis)
        case .expanded:
            return PostureObservation(width: 760, height: 844, foldState: .flat, hingeAngleDegrees: 180, timestampMillis: millis)
        case .transitioning:
            return PostureObservation(width: 560, height: 844, foldState: .transitioning, hingeAngleDegrees: 90, timestampMillis: millis)
        case .halfOpened:
            return PostureObservation(width: 760, height: 844, foldState: .halfOpened, hingeAngleDegrees: 110, timestampMillis: millis)
        case .book:
            return PostureObservation(width: 844, height: 760, foldState: .halfOpened, hingeAngleDegrees: 120, timestampMillis: millis)
        }
    }
}

public struct ScriptStep: Sendable, Hashable {
    public var keyword: PostureKeyword
    public var atMillis: Int64

    public init(keyword: PostureKeyword, atMillis: Int64) {
        self.keyword = keyword
        self.atMillis = max(0, atMillis)
    }
}

/// `compact, transitioning@200, expanded@600` — a comma-separated list of
/// keywords, each optionally suffixed with `@<millis>`. Steps without a time
/// are placed `defaultGapMillis` after the previous step. Anything the parser
/// does not understand is reported, never trapped on; a malformed launch
/// argument must not crash the app it is meant to test.
public struct PostureScript: Sendable, Hashable {
    public var steps: [ScriptStep]

    public init(steps: [ScriptStep]) {
        self.steps = steps
    }

    public enum ParseError: Error, Sendable, Hashable, CustomStringConvertible {
        case unknownKeyword(String)
        case invalidTime(String)
        case empty

        public var description: String {
            switch self {
            case .unknownKeyword(let word): return "unknown posture keyword '\(word)'"
            case .invalidTime(let raw): return "invalid time '\(raw)'"
            case .empty: return "script is empty"
            }
        }
    }

    public static func parse(_ text: String, defaultGapMillis: Int64 = 250) -> Result<PostureScript, ParseError> {
        let gap = max(0, defaultGapMillis)
        let tokens = text
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return .failure(.empty) }

        var steps: [ScriptStep] = []
        var cursor: Int64 = 0
        for token in tokens {
            let parts = token.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            let word = parts.first.map(String.init) ?? ""
            guard let keyword = PostureKeyword(rawValue: word) else {
                return .failure(.unknownKeyword(word))
            }
            var at = cursor
            if parts.count > 1 {
                let raw = String(parts[1]).trimmingCharacters(in: .whitespaces)
                let digits = raw.hasSuffix("ms") ? String(raw.dropLast(2)) : raw
                guard let parsed = Int64(digits), parsed >= 0 else {
                    return .failure(.invalidTime(raw))
                }
                at = parsed
            }
            steps.append(ScriptStep(keyword: keyword, atMillis: at))
            cursor = at > Int64.max - gap ? Int64.max : at + gap
        }
        return .success(PostureScript(steps: steps))
    }

    public var observations: [PostureObservation] {
        steps.map { $0.keyword.observation(at: $0.atMillis) }
    }

    /// Reads the script from process launch arguments, e.g.
    /// `-posture-script "compact,transitioning@200,expanded@600"`. Returns
    /// `nil` when the flag is absent so a normal launch is unaffected.
    public static func fromLaunchArguments(
        _ arguments: [String],
        flag: String = "-posture-script"
    ) -> Result<PostureScript, ParseError>? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { return .failure(.empty) }
        return parse(arguments[next])
    }
}

/// Plays a script through the coordinator, optionally pacing by the script's
/// timestamps. Pacing is off by default so tests are instant.
public struct ScriptedPostureReader: PostureReader {
    public var script: PostureScript
    public var paced: Bool

    public init(script: PostureScript, paced: Bool = false) {
        self.script = script
        self.paced = paced
    }

    public func observations() -> AsyncStream<PostureObservation> {
        let steps = script.observations
        let paced = self.paced
        return AsyncStream { continuation in
            let task = Task {
                var previous: Int64 = steps.first?.timestampMillis ?? 0
                for observation in steps {
                    if paced {
                        let delta = max(0, observation.timestampMillis &- previous)
                        if delta > 0 {
                            try? await Task.sleep(nanoseconds: UInt64(delta) * 1_000_000)
                        }
                        previous = observation.timestampMillis
                    }
                    if Task.isCancelled { break }
                    continuation.yield(observation)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Driving

extension ContinuityCoordinator {
    /// Consumes a reader to completion, ingesting every observation. The
    /// `for await` here is the one suspension point in the coordinator's
    /// public surface, and it is safe: `ingest` is itself synchronous, so
    /// each observation is applied atomically and any call that interleaves
    /// between two observations sees a consistent state.
    @discardableResult
    public func drive(_ reader: some PostureReader) async -> [IngestOutcome] {
        var outcomes: [IngestOutcome] = []
        for await observation in reader.observations() {
            outcomes.append(ingest(observation))
        }
        return outcomes
    }
}
