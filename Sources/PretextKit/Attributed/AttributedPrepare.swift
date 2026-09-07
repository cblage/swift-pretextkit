import CoreGraphics
import CoreText
import Foundation

// MARK: - Attributed Prepare (Rich Runs, Any Thread)
//
// The plain `prepare()` measures one string in one font. This entry point
// measures an attributed string with whatever fonts and kerning its runs
// carry, so a line of mixed faces (prose, a code span, a heading) breaks
// where CoreText would break it, and an attachment (U+FFFC) becomes one
// unbreakable segment of the width the caller reports for it.
//
// Only the measurement stage differs. The segmenter and the line walker are
// the same code the plain path uses; they see widths and break kinds and
// nothing else. Every segment records its UTF-16 range in the source string
// so a laid-out line can be cut from the original attributed string and
// handed to `CTLineCreateWithAttributedString` for drawing, and its
// typographic ascent and descent so a line's height can follow its content.
//
// Whitespace is always pre-wrap here, and the source is analysed as-is, with
// no normalisation pass: offsets must map back to the caller's string.

/// Metrics for an attachment (U+FFFC object replacement) the caller knows
/// and CoreText does not. The segment takes this width and these metrics
/// instead of a measurement.
public struct AttachmentMetrics: Sendable {
    public var width: CGFloat
    public var ascent: CGFloat
    public var descent: CGFloat

    public init(width: CGFloat, ascent: CGFloat, descent: CGFloat) {
        self.width = width
        self.ascent = ascent
        self.descent = descent
    }
}

/// The prepared form of an attributed string. Thread-safe and immutable.
///
/// Segment indices are shared with `LayoutCursor` and `LayoutLineRange`;
/// `utf16Range(of:)` maps a laid-out line back onto the source string.
public struct PreparedAttributedText: @unchecked Sendable {
    let core: PreparedCore

    /// The text of each segment, in order.
    public let segments: [String]

    /// UTF-16 location of each segment in the source string.
    public let utf16Starts: [Int]

    /// UTF-16 length of each segment.
    public let utf16Lengths: [Int]

    /// Typographic ascent of each segment, from the fonts its runs carry.
    public let ascents: [Float]

    /// Typographic descent of each segment.
    public let descents: [Float]

    /// UTF-16 length of the source string.
    public let sourceLength: Int

    public var segmentCount: Int { segments.count }
    public var isEmpty: Bool { segments.isEmpty }
    public var kinds: [SegmentBreakKind] { core.kinds }
    public var widths: [Float] { core.widths }

    /// The UTF-16 offset a cursor stands at. A cursor at or past the last
    /// segment is the end of the string.
    public func utf16Offset(of cursor: LayoutCursor) -> Int {
        guard cursor.segmentIndex < segments.count else { return sourceLength }
        var offset = utf16Starts[cursor.segmentIndex]
        if cursor.graphemeIndex > 0 {
            offset += segments[cursor.segmentIndex].prefix(cursor.graphemeIndex).utf16.count
        }
        return offset
    }

    /// The source range a laid-out line covers, hard-break character included
    /// when the line ends on one.
    public func utf16Range(of line: LayoutLineRange) -> NSRange {
        let start = utf16Offset(of: line.start)
        let end = max(start, utf16Offset(of: line.end))
        return NSRange(location: start, length: end - start)
    }

    /// The cursor at the first segment starting at or after a UTF-16 offset.
    public func cursor(atUTF16 offset: Int) -> LayoutCursor {
        var low = 0
        var high = utf16Starts.count
        while low < high {
            let mid = (low + high) / 2
            if utf16Starts[mid] < offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return LayoutCursor(segmentIndex: low, graphemeIndex: 0)
    }

    /// The tallest ascent and descent among a line's segments. Zero for a
    /// line covering no segments.
    public func lineMetrics(of line: LayoutLineRange) -> (ascent: CGFloat, descent: CGFloat) {
        let first = min(line.start.segmentIndex, segments.count)
        var last = min(line.end.segmentIndex, segments.count)
        if line.end.graphemeIndex > 0 { last = min(last + 1, segments.count) }
        guard first < last else { return (0, 0) }
        var ascent: Float = 0
        var descent: Float = 0
        for i in first..<last {
            ascent = max(ascent, ascents[i])
            descent = max(descent, descents[i])
        }
        return (CGFloat(ascent), CGFloat(descent))
    }
}

extension PreparedAttributedText {
    /// The same text at another scale: every width, advance, ascent, and
    /// descent multiplied by `factor` — pure arithmetic, no measuring — for
    /// a caller whose fonts scale uniformly, an interface zoom: the breaks
    /// the scaled text would take, from the prepare it already has.
    public func scaled(by factor: CGFloat) -> PreparedAttributedText {
        let f = Float(factor)
        return PreparedAttributedText(
            core: core.scaled(by: f),
            segments: segments,
            utf16Starts: utf16Starts,
            utf16Lengths: utf16Lengths,
            ascents: ascents.map { $0 * f },
            descents: descents.map { $0 * f },
            sourceLength: sourceLength
        )
    }
}

/// Segments and measures an attributed string with its own fonts.
///
/// Expensive and one-time per string; safe on any thread. Reflow afterwards
/// is `layoutNextLine(_:start:maxWidth:)`, pure arithmetic.
///
/// - Parameters:
///   - text: The attributed string. Fonts are read from the `NSFont`
///     attribute key its runs carry (AppKit's and UIKit's `.font`), kerning
///     from `NSKern`.
///   - attachmentMetrics: Asked once per U+FFFC character with its UTF-16
///     location; a non-nil answer makes that character one unbreakable
///     segment of the given width and metrics. Nil, or no closure, measures
///     the character like any other.
public func prepareAttributed(
    _ text: NSAttributedString,
    attachmentMetrics: ((Int) -> AttachmentMetrics?)? = nil
) -> PreparedAttributedText {
    let length = text.length
    guard length > 0 else {
        return PreparedAttributedText(
            core: PreparedCore(
                widths: [], lineEndFitAdvances: [], lineEndPaintAdvances: [], kinds: [],
                simpleLineWalkFastPath: true, breakableWidths: [],
                discretionaryHyphenWidth: 0, tabStopAdvance: 0, chunks: []
            ),
            segments: [], utf16Starts: [], utf16Lengths: [], ascents: [], descents: [],
            sourceLength: 0
        )
    }

    let segmentation = normalizeForAttributed(
        buildMergedSegmentation(text.string, whiteSpace: .preWrap)
    )
    let measurer = AttributedSegmentMeasurer(source: text)
    var builder = AttributedSegmentBuilder()
    builder.reserveCapacity(segmentation.count)

    let spaceWidth = measurer.measure(" ", fontAt: 0).width
    let hyphenWidth = measurer.measure("-", fontAt: 0).width
    let tabStopAdvance = spaceWidth * 8

    for i in 0..<segmentation.count {
        let segmentText = segmentation.texts[i]
        let kind = segmentation.kinds[i]
        let start = segmentation.starts[i]
        let range = NSRange(location: start, length: segmentText.utf16.count)

        switch kind {
        case .softHyphen:
            let metrics = measurer.measure("-", fontAt: start)
            builder.push(
                text: segmentText, range: range, width: 0,
                fitAdvance: metrics.width, paintAdvance: metrics.width,
                kind: kind, ascent: metrics.ascent, descent: metrics.descent
            )

        case .hardBreak, .tab:
            // No width of its own; the line it ends or the tab stop decides.
            // Its font's metrics still give an empty line its height.
            let metrics = measurer.measure(" ", fontAt: start)
            builder.push(
                text: segmentText, range: range, width: 0, fitAdvance: 0, paintAdvance: 0,
                kind: kind, ascent: metrics.ascent, descent: metrics.descent
            )

        case .space, .preservedSpace:
            let metrics = measurer.measure(range)
            builder.push(
                text: segmentText, range: range, width: metrics.width, fitAdvance: 0, paintAdvance: 0,
                kind: kind, ascent: metrics.ascent, descent: metrics.descent
            )

        case .glue:
            let metrics = measurer.measure(range)
            builder.push(
                text: segmentText, range: range, width: metrics.width,
                fitAdvance: metrics.width, paintAdvance: metrics.width,
                kind: kind, ascent: metrics.ascent, descent: metrics.descent
            )

        case .zeroWidthBreak:
            builder.push(
                text: segmentText, range: range, width: 0, fitAdvance: 0, paintAdvance: 0,
                kind: kind, ascent: 0, descent: 0
            )

        case .text:
            if segmentText == objectReplacement, let attachment = attachmentMetrics?(start) {
                let width = Float(attachment.width)
                builder.push(
                    text: segmentText, range: range, width: width, fitAdvance: width, paintAdvance: width,
                    kind: .text, ascent: Float(attachment.ascent), descent: Float(attachment.descent)
                )
                continue
            }
            if isCJK(segmentText) {
                splitCJKIntoGraphemes(segmentText, start: start, measurer: measurer, builder: &builder)
                continue
            }
            let metrics = measurer.measure(range)
            // Per-grapheme widths let an overlong word break inside itself.
            // Measured only for a segment wide enough to ever overflow a
            // line: a CTLine per character across a whole transcript is
            // the most expensive thing in this pass, and a short word
            // never needs it.
            let breakable: ContiguousArray<Float>? =
                (segmentation.isWordLike[i] && segmentText.count > 1
                    && metrics.width > overflowCandidateWidth)
                ? measurer.graphemeWidths(range) : nil
            builder.push(
                text: segmentText, range: range, width: metrics.width,
                fitAdvance: metrics.width, paintAdvance: metrics.width,
                kind: .text, ascent: metrics.ascent, descent: metrics.descent, breakable: breakable
            )
        }
    }

    let core = PreparedCore(
        widths: builder.widths,
        lineEndFitAdvances: builder.lineEndFitAdvances,
        lineEndPaintAdvances: builder.lineEndPaintAdvances,
        kinds: builder.kinds,
        simpleLineWalkFastPath: builder.simpleLineWalkFastPath,
        breakableWidths: builder.breakableWidths,
        discretionaryHyphenWidth: hyphenWidth,
        tabStopAdvance: tabStopAdvance,
        chunks: chunksSplitAtHardBreaks(builder.kinds)
    )
    return PreparedAttributedText(
        core: core,
        segments: builder.segments,
        utf16Starts: builder.starts,
        utf16Lengths: builder.lengths,
        ascents: builder.ascents,
        descents: builder.descents,
        sourceLength: length
    )
}

/// Steps one line at a time through prepared attributed text.
///
/// Returns the next line from `start`, or `nil` once the text is exhausted.
/// Chain the returned line's `end` as the next `start`. Each call may take
/// a different width, which is how a paragraph's first-line and head
/// indents are applied. Geometry only: map the line onto the source with
/// `PreparedAttributedText.utf16Range(of:)` and draw that range yourself.
///
/// A segment wider than `maxWidth` breaks inside itself when the prepare
/// measured its graphemes — a word-like segment wide enough to ever
/// overflow a line — so the line ends at the last grapheme that fits and
/// the next line starts inside the segment; any other segment is taken
/// whole and overflows.
///
/// `tabStopAdvance` overrides the prepare's eight-space tab stop for this
/// line: a caller laying out a paragraph with its own tab interval passes
/// it here, so the walk and the drawing agree on where a tab lands.
public func layoutNextLine(
    _ prepared: PreparedAttributedText,
    start: LayoutCursor,
    maxWidth: CGFloat,
    tabStopAdvance: CGFloat? = nil
) -> LayoutLineRange? {
    guard start.segmentIndex < prepared.segments.count else { return nil }
    var result: LayoutLineRange?
    walkSingleLine(
        prepared.core, segments: prepared.segments, start: start, maxWidth: Float(maxWidth),
        tabStopAdvance: tabStopAdvance.map { Float($0) }
    ) { line in
        result = LayoutLineRange(
            width: CGFloat(line.width),
            start: LayoutCursor(segmentIndex: line.startSegmentIndex, graphemeIndex: line.startGraphemeIndex),
            end: LayoutCursor(segmentIndex: line.endSegmentIndex, graphemeIndex: line.endGraphemeIndex)
        )
    }
    return result
}

// MARK: - Segmentation Adjustments

private let objectReplacement = "\u{FFFC}"

/// A word narrower than this fits any line worth laying out, so it is never
/// measured per grapheme.
private let overflowCandidateWidth: Float = 100

/// Reshapes the shared segmenter's output for attributed use:
/// - a run of hard breaks or tabs becomes one segment per character, so
///   `\n\n` keeps its empty line and `\t\t` advances two stops;
/// - every U+FFFC stands alone as a `.text` segment, so an attachment can
///   take its own width and never breaks a word around it apart.
private func normalizeForAttributed(_ seg: MergedSegmentation) -> MergedSegmentation {
    var texts: [String] = []
    var wordLikes: [Bool] = []
    var kinds: [SegmentBreakKind] = []
    var starts: [Int] = []
    texts.reserveCapacity(seg.count)
    wordLikes.reserveCapacity(seg.count)
    kinds.reserveCapacity(seg.count)
    starts.reserveCapacity(seg.count)

    func append(_ text: String, _ wordLike: Bool, _ kind: SegmentBreakKind, _ start: Int) {
        texts.append(text)
        wordLikes.append(wordLike)
        kinds.append(kind)
        starts.append(start)
    }

    for i in 0..<seg.count {
        let text = seg.texts[i]
        let kind = seg.kinds[i]
        let start = seg.starts[i]

        if (kind == .hardBreak || kind == .tab), text.utf16.count > 1 {
            var offset = 0
            for scalar in text.unicodeScalars {
                append(String(scalar), false, kind, start + offset)
                offset += scalar.utf16.count
            }
            continue
        }

        if kind == .text, text.unicodeScalars.contains("\u{FFFC}") {
            var piece = ""
            var pieceStart = start
            var offset = 0
            for scalar in text.unicodeScalars {
                if scalar == "\u{FFFC}" {
                    if !piece.isEmpty {
                        append(piece, seg.isWordLike[i], .text, pieceStart)
                        piece = ""
                    }
                    append(objectReplacement, true, .text, start + offset)
                    pieceStart = start + offset + 1
                } else {
                    piece.unicodeScalars.append(scalar)
                }
                offset += scalar.utf16.count
            }
            if !piece.isEmpty {
                append(piece, seg.isWordLike[i], .text, pieceStart)
            }
            continue
        }

        append(text, seg.isWordLike[i], kind, start)
    }

    return MergedSegmentation(texts: texts, isWordLike: wordLikes, kinds: kinds, starts: starts)
}

/// Chunk boundaries at hard breaks, over the final segment list.
private func chunksSplitAtHardBreaks(_ kinds: [SegmentBreakKind]) -> [PreparedLineChunk] {
    var chunks: [PreparedLineChunk] = []
    var chunkStart = 0
    for i in 0..<kinds.count where kinds[i] == .hardBreak {
        chunks.append(PreparedLineChunk(
            startSegmentIndex: chunkStart,
            endSegmentIndex: i,
            consumedEndSegmentIndex: i + 1
        ))
        chunkStart = i + 1
    }
    if chunkStart < kinds.count {
        chunks.append(PreparedLineChunk(
            startSegmentIndex: chunkStart,
            endSegmentIndex: kinds.count,
            consumedEndSegmentIndex: kinds.count
        ))
    }
    return chunks
}

// MARK: - CJK Grapheme Splitting

/// Each CJK grapheme becomes its own segment, kinsoku characters sticking to
/// their neighbours, as the plain path does — with the source offsets
/// carried through.
private func splitCJKIntoGraphemes(
    _ text: String,
    start: Int,
    measurer: AttributedSegmentMeasurer,
    builder: inout AttributedSegmentBuilder
) {
    var unitText = ""
    var unitStart = start
    var offset = 0

    func flush() {
        guard !unitText.isEmpty else { return }
        let range = NSRange(location: unitStart, length: unitText.utf16.count)
        let metrics = measurer.measure(range)
        builder.push(
            text: unitText, range: range, width: metrics.width,
            fitAdvance: metrics.width, paintAdvance: metrics.width,
            kind: .text, ascent: metrics.ascent, descent: metrics.descent
        )
    }

    for char in text {
        let grapheme = String(char)
        let graphemeLength = grapheme.utf16.count
        defer { offset += graphemeLength }

        if unitText.isEmpty {
            unitText = grapheme
            unitStart = start + offset
            continue
        }

        let graphemeScalar = grapheme.unicodeScalars.first!
        if isKinsokuEndUnit(unitText)
            || kinsokuStartScalars.contains(graphemeScalar)
            || leftStickyPunctuation.contains(graphemeScalar) {
            unitText += grapheme
            continue
        }

        flush()
        unitText = grapheme
        unitStart = start + offset
    }
    flush()
}

private func isKinsokuEndUnit(_ text: String) -> Bool {
    for scalar in text.unicodeScalars where !kinsokuEndScalars.contains(scalar) {
        return false
    }
    return !text.isEmpty
}

// MARK: - Builder

/// Collects measured segments with their source ranges and vertical metrics.
private struct AttributedSegmentBuilder {
    var widths: [Float] = []
    var lineEndFitAdvances: [Float] = []
    var lineEndPaintAdvances: [Float] = []
    var kinds: [SegmentBreakKind] = []
    var breakableWidths: [ContiguousArray<Float>?] = []
    var segments: [String] = []
    var starts: [Int] = []
    var lengths: [Int] = []
    var ascents: [Float] = []
    var descents: [Float] = []
    var simpleLineWalkFastPath = true

    mutating func reserveCapacity(_ n: Int) {
        widths.reserveCapacity(n)
        lineEndFitAdvances.reserveCapacity(n)
        lineEndPaintAdvances.reserveCapacity(n)
        kinds.reserveCapacity(n)
        breakableWidths.reserveCapacity(n)
        segments.reserveCapacity(n)
        starts.reserveCapacity(n)
        lengths.reserveCapacity(n)
        ascents.reserveCapacity(n)
        descents.reserveCapacity(n)
    }

    mutating func push(
        text: String,
        range: NSRange,
        width: Float,
        fitAdvance: Float,
        paintAdvance: Float,
        kind: SegmentBreakKind,
        ascent: Float,
        descent: Float,
        breakable: ContiguousArray<Float>? = nil
    ) {
        widths.append(width)
        lineEndFitAdvances.append(fitAdvance)
        lineEndPaintAdvances.append(paintAdvance)
        kinds.append(kind)
        breakableWidths.append(breakable)
        segments.append(text)
        starts.append(range.location)
        lengths.append(range.length)
        ascents.append(ascent)
        descents.append(descent)
        if kind != .text && kind != .space && kind != .zeroWidthBreak {
            simpleLineWalkFastPath = false
        }
    }
}

// MARK: - Measurement

/// Measures ranges of one attributed string with the fonts and kerning its
/// runs carry, through a reused scratch attributed string. One instance per
/// prepare, used from that thread alone.
private final class AttributedSegmentMeasurer {
    struct Metrics {
        var width: Float
        var ascent: Float
        var descent: Float
    }

    /// AppKit's and UIKit's `.font` and `.kern` keys, by their raw names,
    /// so this file needs neither framework.
    private static let fontKey = NSAttributedString.Key("NSFont")
    private static let kernKey = NSAttributedString.Key("NSKern")

    private let source: NSAttributedString
    private let scratch: CFMutableAttributedString

    init(source: NSAttributedString) {
        self.source = source
        self.scratch = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)
    }

    /// The typographic width and metrics of a source range, its runs' fonts
    /// and kerning applied.
    func measure(_ range: NSRange) -> Metrics {
        let sub = source.attributedSubstring(from: range)
        resetScratch(with: sub.string)
        sub.enumerateAttributes(in: NSRange(location: 0, length: sub.length), options: []) { attrs, runRange, _ in
            apply(attrs, to: runRange)
        }
        return measureScratch()
    }

    /// A string measured in the font found at a source location.
    func measure(_ string: String, fontAt location: Int) -> Metrics {
        resetScratch(with: string)
        let length = source.length
        if length > 0 {
            let index = min(max(location, 0), length - 1)
            let attrs = source.attributes(at: index, effectiveRange: nil)
            apply(attrs, to: NSRange(location: 0, length: (string as NSString).length))
        }
        return measureScratch()
    }

    /// Each grapheme's own width within a range, for overflow breaking.
    func graphemeWidths(_ range: NSRange) -> ContiguousArray<Float> {
        let text = (source.string as NSString).substring(with: range)
        var widths = ContiguousArray<Float>()
        widths.reserveCapacity(text.count)
        var offset = range.location
        for char in text {
            let length = String(char).utf16.count
            widths.append(measure(NSRange(location: offset, length: length)).width)
            offset += length
        }
        return widths
    }

    private func resetScratch(with string: String) {
        let current = CFAttributedStringGetLength(scratch)
        CFAttributedStringReplaceString(scratch, CFRangeMake(0, current), string as CFString)
        let length = CFAttributedStringGetLength(scratch)
        if length > 0 {
            CFAttributedStringSetAttributes(scratch, CFRangeMake(0, length), [:] as CFDictionary, true)
        }
    }

    private func apply(_ attrs: [NSAttributedString.Key: Any], to range: NSRange) {
        let cfRange = CFRangeMake(range.location, range.length)
        if let font = attrs[Self.fontKey] {
            CFAttributedStringSetAttribute(scratch, cfRange, kCTFontAttributeName, font as AnyObject)
        }
        if let kern = attrs[Self.kernKey] {
            CFAttributedStringSetAttribute(scratch, cfRange, kCTKernAttributeName, kern as AnyObject)
        }
    }

    private func measureScratch() -> Metrics {
        let line = CTLineCreateWithAttributedString(scratch)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return Metrics(width: Float(width), ascent: Float(ascent), descent: Float(descent))
    }
}
