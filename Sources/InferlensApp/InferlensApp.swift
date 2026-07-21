// InferlensApp — the THIN app target: composition only, CLAUDE.md's own word for it. Every seam
// closed here had its shape recorded before this file existed — the engine is named here and
// nowhere else (ADR-0001: the UI sees the protocol), the summarize closure is ADR-0008's one
// line, the RunSink closes over a RunLedger through the RunRecord composition initializer, and
// the export action drives LedgerExport at the only place that knows where the ledger file is.
// If this file ever needs more than a screenful of code, something has leaked out of a module —
// the rule is a hard stop, not a preference.

import InferlensBench
import InferlensCore
import InferlensCoreML
import InferlensFallback
import InferlensLiteRT
import InferlensRemote
import InferlensStore
import InferlensUI
import SwiftUI
import UIKit

@main
struct InferlensApp: App {
    private let model: ClassificationModel
    private let ledger: RunLedger
    private let ledgerURL: URL

    init() {
        let ledgerURL = Self.ledgerLocation()
        let ledger = RunLedger(location: .file(ledgerURL))

        // The chain, deliberately and reversibly: LiteRT leads (the vendored artifact's device
        // slice is verified — ADR-0002 — though the engine has never yet run on hardware), Core
        // ML backs it up, and the remote leg is a real `RemoteEngine` composed UNCONFIGURED. This line is
        // the whole swap: assign a bare engine here to reverse it, and record the reason at this
        // line. A missing model file is no longer a dead end (the rung-24 comment's
        // "failed(retryable: false)" claim was retired by this chain): a failed LiteRT load
        // walks to Core ML and the run succeeds degraded — fellBack(liteRT -> coreML) on screen
        // and in the ledger row, the same fact in both places (invariant 3).
        let tfliteURL = Bundle.module.url(
            forResource: "mobilenet_v2_1.0_224", withExtension: "tflite", subdirectory: "Models"
        ) ?? Bundle.module.bundleURL.appendingPathComponent("Models/mobilenet_v2_1.0_224.tflite")
        let coreMLURL = Bundle.module.url(
            forResource: "MobileNetV2FP16", withExtension: "mlmodel", subdirectory: "Models"
        ) ?? Bundle.module.bundleURL.appendingPathComponent("Models/MobileNetV2FP16.mlmodel")
        // ONE table, both engines. Loading is composition's job — `LabelTable` is a value and Core
        // reads no files — so the bytes are read here, once, and handed to whichever engines answer.
        // That is what makes the word on screen independent of which leg the chain reached: a
        // fallback from LiteRT to Core ML changes the backend line, never the vocabulary.
        //
        // `nil` when the resource is missing, and that is a real path rather than a defensive
        // gesture: the table is derived by `make bootstrap` (invariant 8), so a tree that skipped
        // bootstrap has no file here. The app then labels classes `"class 653"` exactly as it did
        // before this rung — readable-by-nobody, but true.
        let labels = Bundle.module.url(
            forResource: "imagenet_labels", withExtension: "txt", subdirectory: "Models"
        ).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map(LabelTable.init(text:))

        // `endpoint: nil` is the whole of what ships, and it is a decision on record (ADR-0013,
        // Decision 3): the leg is real code with a documented wire contract and a suite that runs
        // it against a loopback server, and NO PUBLIC ENDPOINT SHIPS. Unconfigured it throws
        // `.backendUnavailable` from `loadModel()` — byte-for-byte the behaviour the deleted stub
        // had — so the degradation story on screen and in the ledger is unchanged for users.
        // Configuring it is one argument at this line, which is what makes the thesis's "choose
        // next model/backend" a real choice rather than a sentence.
        let engine = FallbackEngine(legs: [
            .init(engine: LiteRTEngine(modelURL: tfliteURL, labels: labels), backend: .liteRT),
            .init(engine: CoreMLEngine(modelURL: coreMLURL, labels: labels), backend: .coreML),
            .init(engine: RemoteEngine(endpoint: nil, labels: labels), backend: .remote),
        ])

        // The sink may run before open() completes: an early append throws .notOpen, `try?`
        // answers nil, and the screen is untouched — the seam's contract, not an edge case.
        let device = DeviceIdentity.current
        let sink = RunSink(
            appendRun: { sample, outcome in
                try? await ledger.append(
                    RunRecord(
                        outcome: outcome,
                        sample: sample,
                        model: Self.descriptor(for: outcome.backend),
                        device: device,
                        recordedAt: Date()
                    )
                )
            },
            appendSignal: { runID, verdict in
                _ = try? await ledger.appendSignal(runID: runID, verdict: verdict, recordedAt: Date())
            }
        )

        model = ClassificationModel(
            engine: engine,
            latency: LatencySource(
                device: device.model,
                os: device.osVersion,
                summarize: { try? LatencyRecorder().summarize($0) }
            ),
            sink: sink
        )
        self.ledger = ledger
        self.ledgerURL = ledgerURL

        // Flags: deliberately absent. Wired at rung 28, when the paywall flag gives `isEnabled`
        // its first caller — the rung-19/20 no-producer rule, applied at the composition level.
    }

    var body: some Scene {
        WindowGroup {
            ComposedScreen(model: model, ledger: ledger, ledgerURL: ledgerURL)
        }
    }

    /// The ledger row names the model that ACTUALLY answered (ADR-0010): the chain's own
    /// descriptor is fixed to its preferred leg, so the composition — the one place that knows
    /// which engine wears which backend — picks per row from `outcome.backend`. Exhaustive on
    /// purpose: a new `Backend` case must force a decision here. `.remote` still never reaches a
    /// row in the shipped app, because the leg is composed with no endpoint; it maps to the remote
    /// leg's declared descriptor, which is what a configured build would record.
    private static func descriptor(for backend: Backend) -> ModelDescriptor {
        switch backend {
        case .liteRT: .googleMobileNetV2FP32
        case .coreML: .appleMobileNetV2FP16
        case .remote: .remote
        }
    }

    /// `<Application Support>/ledger.sqlite` (ADR-0006). The directory may not exist in a fresh
    /// sandbox; a creation failure flows into `open()`'s `.cannotOpen`, after which every sink
    /// write answers nil and export stays disabled — the app degrades to exactly what it was
    /// before rung 25, instead of trapping.
    private static func ledgerLocation() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("ledger.sqlite")
    }
}

/// The screen plus the one action that belongs to the composition, not the UI module: exporting
/// the ledger. InferlensUI cannot name `LedgerExport` (it cannot import Store), so the toolbar
/// button lives here, beside the only code that knows where the ledger file is.
private struct ComposedScreen: View {
    let model: ClassificationModel
    let ledger: RunLedger
    let ledgerURL: URL

    /// Non-nil exactly while a generated file is being offered. Presentation is keyed on it, and
    /// each tap generates a FRESH temp URL: the NDJSON is derived and disposable, never cached —
    /// the ledger is the record, the file is a view of it.
    @State private var exported: ExportedFile?
    @State private var canExport = false

    var body: some View {
        NavigationStack {
            ClassificationScreen(model: model)
                .navigationTitle("Inferlens")
                .toolbar {
                    // An ACTION, enabled when the ledger has rows — not a state: the machine has
                    // no case for exporting and gains none (invariant 4), so this can never
                    // change what the screen shows.
                    Button("Export runs", systemImage: "square.and.arrow.up") {
                        Task { await export() }
                    }
                    .disabled(!canExport)
                }
        }
        .task {
            try? await ledger.open()
            await refreshCanExport()
        }
        .onChange(of: model.state) {
            Task { await refreshCanExport() }
        }
        .sheet(item: $exported) { file in
            ShareSheet(url: file.url)
        }
    }

    private func refreshCanExport() async {
        canExport = (try? await ledger.recentRuns(limit: 1))?.isEmpty == false
    }

    /// Generation runs off the main actor and off the ledger's write path — `LedgerExport` opens
    /// its own read-only connection against the file, so a run finishing mid-export is never
    /// blocked. A failed generation presents nothing: there is no state case for it (invariant 4),
    /// and the button staying enabled is the honest surface — the ledger is intact, try again.
    private func export() async {
        let source = ledgerURL
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("inferlens-runs-\(UUID().uuidString).ndjson")
        let generated = await Task.detached {
            (try? LedgerExport.export(ledgerAt: source, to: destination)) != nil
        }.value
        if generated { exported = ExportedFile(url: destination) }
    }
}

private struct ExportedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// SwiftUI's `ShareLink` wants its item up front, and this file exists only after the tap that
/// asks for it — so the UIKit sheet is wrapped, the smallest possible adapter. It lives in the
/// app target because presenting a share sheet is composition chrome, not UI-module vocabulary.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context: Context) {}
}
