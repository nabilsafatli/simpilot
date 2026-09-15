import Foundation
import Observation

/// Holds the loaded inventory and storage report for the UI.
///
/// Lives in the package rather than the app target so that loading, failure and
/// refresh behaviour can be tested with `swift test` against recorded simctl
/// output, exactly like the layers beneath it.
@MainActor
@Observable
public final class InventoryStore {

    public enum LoadState: Sendable {
        case idle
        /// Reading the inventory. Sizes are not known yet.
        case loading
        /// Inventory is available; the filesystem walk is still running.
        case scanning(ScanProgress?)
        case ready
        case failed(String)
        /// simctl is unreachable — usually Xcode is absent or `xcode-select`
        /// points somewhere without it. A distinct state from "no devices",
        /// which would otherwise read as an empty but working Mac.
        case toolchainUnavailable(String)

        public var isBusy: Bool {
            switch self {
            case .loading, .scanning: true
            default: false
            }
        }
    }

    public private(set) var state: LoadState = .idle
    public private(set) var inventory: SimulatorInventory?
    public private(set) var report: SimulatorStorageReport?
    public private(set) var lastRefreshedAt: Date?

    /// Recommendations for the loaded inventory.
    ///
    /// Recomputed after each refresh rather than cached against a stale snapshot:
    /// advice about devices that no longer exist would be worse than none.
    public private(set) var recommendationReport: RecommendationReport?

    /// Result of the most recent cleanup, retained until the next one so the user
    /// can read what happened after the inventory has already refreshed beneath it.
    public private(set) var cleanupOutcome: CleanupOutcome?
    /// The operation currently running, for progress. Nil when nothing is running.
    public private(set) var executingOperation: CleanupOperation?
    public private(set) var isExecutingCleanup = false

    private let engine: RecommendationEngine
    private let service: any SimulatorService
    private let scannerFactory: @Sendable (@escaping @Sendable (ScanProgress) -> Void) -> any SimulatorStorageScanner
    private var refreshTask: Task<Void, Never>?

    public init(
        service: any SimulatorService,
        engine: RecommendationEngine = RecommendationEngine(),
        scannerFactory: @escaping @Sendable (@escaping @Sendable (ScanProgress) -> Void) -> any SimulatorStorageScanner
            = { handler in FileSystemStorageScanner(progressHandler: handler) }
    ) {
        self.service = service
        self.engine = engine
        self.scannerFactory = scannerFactory
    }

    public static func live() -> InventoryStore {
        InventoryStore(service: SimctlSimulatorService())
    }

    // MARK: - Derived views of the data

    public var rows: [DeviceRow] {
        guard let inventory else { return [] }
        return DeviceRow.rows(inventory: inventory, report: report)
    }

    public var summary: DashboardSummary? {
        inventory.map { DashboardSummary(inventory: $0, report: report) }
    }

    public var runtimes: [SimulatorRuntime] { inventory?.runtimes ?? [] }

    public var recommendations: [Recommendation] {
        recommendationReport?.recommendations ?? []
    }

    /// Space the actionable recommendations could free. Excludes reviews, which
    /// are not pending deletions.
    public var actionableRecoverableBytes: Int64 {
        recommendationReport?.actionableRecoverableBytes ?? 0
    }

    /// Entries simctl reported that could not be read. Shown rather than hidden,
    /// so the inventory never implies completeness it does not have.
    public var parseIssues: [ParseIssue] { inventory?.issues ?? [] }

    public func deviceCount(forRuntime runtimeIdentifier: String) -> Int {
        inventory?.devices(forRuntime: runtimeIdentifier).count ?? 0
    }

    /// Measured size of every device on a runtime — what removing it would strand,
    /// which is not the same as what deleting the runtime itself recovers.
    public func deviceBytes(forRuntime runtimeIdentifier: String) -> Int64 {
        guard let inventory, let report else { return 0 }
        return inventory.devices(forRuntime: runtimeIdentifier)
            .compactMap { report.storage(forDevice: $0.id)?.totalBytes }
            .reduce(0, +)
    }

    // MARK: - Loading

    public func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { await performRefresh() }
    }

    public func refreshAndWait() async {
        refreshTask?.cancel()
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
    }

    private func performRefresh() async {
        state = .loading

        let loaded: SimulatorInventory
        do {
            loaded = try await service.loadInventory()
        } catch let error as SimctlError {
            // A failure to list at all means the toolchain, not the data.
            state = .toolchainUnavailable(error.errorDescription ?? "\(error)")
            return
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        guard !Task.isCancelled else { return }
        inventory = loaded
        // A first pass without measured sizes: Rule C cannot fire yet, but the
        // rules that need no filesystem data give the user something immediately.
        recommendationReport = engine.evaluate(inventory: loaded, report: nil)
        // Runtime sizes are already known from simctl, so the UI has real figures
        // to show while the filesystem walk runs.
        state = .scanning(nil)

        let scanner = scannerFactory { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, case .scanning = self.state else { return }
                self.state = .scanning(progress)
            }
        }

        do {
            let scanned = try await scanner.scan(inventory: loaded)
            guard !Task.isCancelled else { return }
            report = scanned
            // Re-evaluated now that sizes are known, so size-dependent rules and
            // recoverable-space figures reflect measurement rather than absence.
            recommendationReport = engine.evaluate(inventory: loaded, report: scanned)
            lastRefreshedAt = Date()
            state = .ready
        } catch is CancellationError {
            return
        } catch {
            // The inventory is still usable without measured sizes, so a failed
            // scan degrades the display rather than emptying the screen.
            lastRefreshedAt = Date()
            state = .ready
        }
    }

    // MARK: - Cleanup
    //
    // Building a plan is inert. Only ``executeCleanup`` mutates anything, and it
    // is only ever reached from a confirmation the user gave on a screen that
    // named every target.

    /// Assembles a plan from the recommendations the user selected.
    /// Runs nothing.
    public func plan(for selected: [Recommendation]) -> CleanupPlan {
        guard let inventory else { return CleanupPlan(operations: []) }
        return CleanupPlan.build(from: selected, inventory: inventory, report: report)
    }

    /// Executes a confirmed plan, then re-reads the machine to measure what was
    /// actually recovered.
    ///
    /// Recovery is measured rather than predicted: the plan's estimate and the
    /// re-scan's result are both kept so the two can be shown side by side. APFS
    /// clones mean they can legitimately differ.
    public func executeCleanup(_ plan: CleanupPlan) async {
        guard !plan.isEmpty, !isExecutingCleanup else { return }

        isExecutingCleanup = true
        cleanupOutcome = nil
        let bytesBefore = report?.totalBytes

        let executor = CleanupExecutor(service: service)
        let outcome = await executor.execute(plan) { [weak self] operation in
            Task { @MainActor [weak self] in self?.executingOperation = operation }
        }

        executingOperation = nil

        // Re-read inventory and sizes before reporting, so the figures shown are
        // measured rather than inferred from what was asked for.
        await performRefresh()

        let bytesAfter = report?.totalBytes
        let measured: Int64? = {
            guard let bytesBefore, let bytesAfter else { return nil }
            return max(bytesBefore - bytesAfter, 0)
        }()

        cleanupOutcome = CleanupOutcome(
            succeeded: outcome.succeeded,
            failure: outcome.failure,
            notAttempted: outcome.notAttempted,
            measuredRecoveredBytes: measured,
            estimatedRecoverableBytes: outcome.estimatedRecoverableBytes
        )
        isExecutingCleanup = false
    }

    public func dismissCleanupOutcome() {
        cleanupOutcome = nil
    }

    public func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}
