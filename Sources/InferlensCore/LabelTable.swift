// The index → label mapping, as a VALUE. Loading is composition's job; this type only holds and
// answers.
//
// Why this exists. A classifier's output vector is positional: the model emits a score per index and
// nothing else. Core ML classifiers carry their own label strings, so that engine has always
// returned words — but the raw `.tflite` carries none (MODEL_PROVENANCE.md), so the LiteRT engine
// labelled classes `"class 973"`. An ImageNet index is not something a user can judge, which made
// the thumbs signal a measure of how plausible the app FELT rather than of whether it was right.
// This table is what turns a position into a word, so the signal has something to be about.
//
// Where the truth comes from, and why it is not a list off the web. The table is derived at
// `make bootstrap` from Apple's already-checksum-pinned `MobileNetV2FP16.mlmodel`, which embeds its
// own 1001-entry class-label vector (`scripts/extract-labels.py`). Published "canonical ImageNet"
// lists are almost always 1000 entries with no background class, and mapping a 1001-wide output
// through one shifts every label by one. A wrong word under a thumbs button is worse than a bare
// index: an index is merely unreadable, a wrong word is confidently false.
//
// What this type does NOT claim. It does not know which model produced the index it is asked about,
// and it cannot verify that any engine's output ordering matches it — a `LabelTable` is just an
// array with a lookup. That the TFLite model's ordering agrees with this table is established
// outside this file: by the count check at load, by the spot-checks against upstream TensorFlow's
// published `label_image` output, and end to end by the fixture test that runs the real engine on an
// image whose subject is known by looking at it. This type is the mapping, not its justification.

/// An ordered list of class labels, addressed by the index a model emits.
public struct LabelTable: Sendable, Equatable {
    private let labels: [String]

    /// Label → index, for the reverse direction. A label that appears MORE THAN ONCE maps to `nil`
    /// here rather than to its first position — see `index(of:)` for why that is not pedantry.
    private let indicesByLabel: [String: Int?]

    /// - Parameter labels: the labels in model order, index 0 first.
    public init(_ labels: [String]) {
        self.labels = labels

        var indices: [String: Int?] = [:]
        indices.reserveCapacity(labels.count)
        for (index, label) in labels.enumerated() {
            if indices[label] != nil {
                // Seen before: the label is ambiguous, so it maps to no single index.
                indices[label] = .some(nil)
            } else {
                indices[label] = .some(index)
            }
        }
        indicesByLabel = indices
    }

    /// Parse a newline-delimited table — the format `make bootstrap` derives. Pure: it takes text,
    /// not a path. Reading the file is the composition's job, which is what keeps this module free
    /// of every dependency including Foundation's file APIs.
    ///
    /// Blank lines are dropped rather than kept as empty labels, so a trailing newline (which the
    /// derived file has, and which every well-formed text file should) does not silently add a
    /// 1002nd class that shifts nothing but reports the wrong count.
    ///
    /// Split on `isNewline`, NOT on the literal `"\n"`. Swift strings are sequences of grapheme
    /// clusters and `"\r\n"` is ONE of them, so a literal `"\n"` separator does not match a CRLF line
    /// ending at all — it leaves the terminator attached and yields labels like `"background\r\n"`.
    /// Found by the CRLF case in `LabelTableTests`, which failed exactly this way before this line
    /// said `isNewline`.
    public init(text: String) {
        self.init(
            text.split(whereSeparator: \.isNewline)
                .map { String($0).trimmingASCIIWhitespace() }
                .filter { !$0.isEmpty }
        )
    }

    /// How many labels the table holds. The caller compares this against the model's own output
    /// dimension — a table whose count differs from the output width cannot be the right table, and
    /// that check is the cheapest guard against the off-by-one this type exists to prevent.
    public var count: Int { labels.count }

    public var isEmpty: Bool { labels.isEmpty }

    /// The label at `index`, or `nil` when the index falls outside the table.
    ///
    /// `nil` rather than a placeholder string, deliberately: the caller decides what an unmappable
    /// index looks like, and every current caller falls back to `fallbackLabel(for:)` — the same
    /// `"class N"` the LiteRT engine emitted before this table existed. An out-of-range index is a
    /// real signal (the table does not match the model), so it must stay distinguishable from a
    /// successful lookup rather than being smoothed into one.
    public func label(at index: Int) -> String? {
        guard index >= 0, index < labels.count else { return nil }
        return labels[index]
    }

    /// The index of `label`, or `nil` when the table does not hold it — **or holds it more than
    /// once**.
    ///
    /// The ambiguity is not hypothetical and not rare enough to ignore: in this table `"crane"`
    /// appears at index 135 (the bird) and index 518 (the machine). They are different classes that
    /// share a word. Returning the first would put a specific, checkable, wrong number on screen
    /// beside a correct label — and a number that is wrong half the time it appears is worse than no
    /// number, because nothing about it looks uncertain.
    ///
    /// This is the direction the Core ML side needs: that engine emits label strings and never an
    /// index, so the index it shows is recovered from this table. For `"crane"` it shows none.
    public func index(of label: String) -> Int? {
        guard let found = indicesByLabel[label] else { return nil }
        return found
    }

    /// What an index with no label looks like: `"class 653"`.
    ///
    /// This is the EXPLICIT fallback, and it is exactly the string the LiteRT engine produced for
    /// every class before this table existed. That is the point — when no table is loaded, or when
    /// one is loaded that does not fit the model, the app degrades to precisely its previous
    /// behaviour instead of to a blank, a placeholder, or a guess.
    public static func fallbackLabel(for index: Int) -> String {
        "class \(index)"
    }
}

private extension String {
    /// Trim spaces, tabs and a stray carriage return. Written out rather than reached for via
    /// Foundation's `trimmingCharacters(in:)` because `InferlensCore` depends on nothing — the
    /// dependency direction in CLAUDE.md is one way, and Foundation is not an exception to it.
    func trimmingASCIIWhitespace() -> String {
        var characters = Substring(self)
        while let first = characters.first, first == " " || first == "\t" || first == "\r" {
            characters = characters.dropFirst()
        }
        while let last = characters.last, last == " " || last == "\t" || last == "\r" {
            characters = characters.dropLast()
        }
        return String(characters)
    }
}
