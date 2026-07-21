// InferlensApp — the THIN app target: composition only, CLAUDE.md's own word for it. Every seam
// closed here had its shape recorded before this file existed — the engine is named here and
// nowhere else (ADR-0001: the UI sees the protocol), the summarize closure is ADR-0008's one
// line, the RunSink closes over a RunLedger through the RunRecord composition initializer, and
// the export action drives LedgerExport at the only place that knows where the ledger file is.
// If this file ever needs more than a screenful of code, something has leaked out of a module —
// the rule is a hard stop, not a preference.

import InferlensBench
import InferlensCore
import InferlensLiteRT
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

        // LiteRT, deliberately and reversibly: the vendored artifact's device slice is verified
        // and a device-destination build has succeeded (ADR-0002), but the engine has never yet
        // run on hardware — if a real device link ever fails, swap in CoreMLEngine here and
        // record the reason at this line. A missing model file is not a crash: the URL flows into
        // loadModel -> .modelLoadFailed -> failed(retryable: false), an honest observable trigger.
        let modelURL = Bundle.module.url(
            forResource: "mobilenet_v2_1.0_224", withExtension: "tflite", subdirectory: "Models"
        ) ?? Bundle.module.bundleURL.appendingPathComponent("Models/mobilenet_v2_1.0_224.tflite")
        let engine = LiteRTEngine(modelURL: modelURL)

        // The sink may run before open() completes: an early append throws .notOpen, `try?`
        // answers nil, and the screen is untouched — the seam's contract, not an edge case.
        let device = DeviceIdentity.current
        let sink = RunSink(
            appendRun: { sample, outcome in
                try? await ledger.append(
                    RunRecord(
                        outcome: outcome,
                        sample: sample,
                        model: .googleMobileNetV2FP32,
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
