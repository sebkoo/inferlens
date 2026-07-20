// The one MVP screen: pick a photo, classify it, see the top three with the backend and p50/p95.
//
// It composes three things that already existed separately — the picker, `InferenceStateView` (the
// state machine's chrome) and `ClassificationResultView` (the payload) — around one
// `ClassificationModel`. The screen itself holds no inference logic and no engine: it turns a
// `PhotosPickerItem` into a `UIImage` and hands it to the model, which is the whole of its job.
//
// What it deliberately does NOT have is a Clear button. See the note at the bottom of
// `ClassificationModel.swift`: returning the machine to `idle` while the engine is loaded strands it,
// because `idle` refuses `.classifyBegan`. Choosing another photo is legal from `success` and from
// `failed`, so the screen offers that instead — and the missing affordance is recorded in ROADMAP
// rather than papered over with an event that lies.

import InferlensCore
import PhotosUI
import SwiftUI

public struct ClassificationScreen: View {
    @State private var model: ClassificationModel
    @State private var pickerItem: PhotosPickerItem?
    @State private var preview: UIImage?

    /// - Parameter model: the driver, already wired to an engine by whoever composes this screen.
    ///   Injected rather than constructed here, because constructing it would mean naming an engine,
    ///   and this module is not allowed to (ADR-0001).
    public init(model: ClassificationModel) {
        _model = State(wrappedValue: model)
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                photo

                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Label(
                        preview == nil ? "Choose a photo" : "Choose another photo",
                        systemImage: "photo.on.rectangle"
                    )
                }
                .buttonStyle(.borderedProminent)

                // The state machine's own view, unchanged by this rung except for the two waits
                // being drawn apart. `onRetry` is supplied only when there is something to retry
                // with — the view's contract is that a `nil` closure means no button is promised.
                InferenceStateView(
                    state: model.state,
                    onRetry: model.canRetry ? { Task { await model.retry() } } : nil
                )

                // The payload, only when there is one. `outcome` is cleared on failure, so this
                // cannot render the previous photo's labels under a new photo's error.
                if let outcome = model.outcome, case .success = model.state {
                    ClassificationResultView(
                        classifications: model.topThree,
                        backend: outcome.backend,
                        readout: model.readout
                    )
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await choose(item) }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var photo: some View {
        if let preview {
            Image(uiImage: preview)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                // The photo is the subject of every other element on the screen, so it is labelled
                // as an image rather than left as an unnamed rectangle to a screen reader.
                .accessibilityLabel("The photo being classified")
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .frame(height: 180)
                .overlay {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
        }
    }

    // MARK: - Picking

    /// Load the picked item's bytes, show them, and run.
    ///
    /// The `UIImage` — not a decoded buffer — is what goes to the model, because the model decodes
    /// INSIDE the run so that an undecodable photo lands on `failed(retryable: false)` rather than
    /// silently doing nothing (see `ClassificationModel.run`). A file the picker cannot even hand
    /// over as `Data` is the one case that cannot reach the machine, and it is treated the same way:
    /// a `UIImage` that cannot be built is passed on as an empty one, so the run fails through the
    /// same path rather than through a second, invisible one.
    private func choose(_ item: PhotosPickerItem) async {
        let data = try? await item.loadTransferable(type: Data.self)
        let image = data.flatMap(UIImage.init(data:))
        preview = image
        await model.classify(photo: image ?? UIImage())
    }
}

// MARK: - Preview

// FABRICATED, like every other preview in this module: no engine is constructed here, so the canvas
// cannot render this one at all without one. Recorded rather than left out, for the same reason the
// other previews stay — see the note in `InferenceStateView.swift` about `ENABLE_DEBUG_DYLIB`.
