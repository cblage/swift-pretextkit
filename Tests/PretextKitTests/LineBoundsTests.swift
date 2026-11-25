import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import PretextKit

/// The bounds a line walk keeps: the walk reads the maximum width only in its
/// comparisons, so `holds(atMaxWidth:)` must be true exactly where a fresh
/// walk from the line's start returns the same line, for each kind of text.
///
/// The hand-built texts are pieces whose widths are exact in binary, measured
/// as the attributed prepare measures them: a word and glue fit with their
/// width, a pre-wrap space, a tab, a hard break and a zero-width break with
/// none, and a soft hyphen with the hyphen's width.
@Suite("Line width bounds")
struct LineBoundsTests {

    // MARK: - Helpers

    private struct Piece {
        let text: String
        let kind: SegmentBreakKind
        let width: Float
        var hyphen: Float = 0
        var graphemes: [Float]? = nil
    }

    private static func word(_ text: String, _ width: Float, graphemes: [Float]? = nil) -> Piece {
        Piece(text: text, kind: .text, width: width, graphemes: graphemes)
    }

    private static func space(_ width: Float) -> Piece {
        Piece(text: " ", kind: .preservedSpace, width: width)
    }

    /// A prepared text of hand-measured pieces, its chunks split at its hard breaks.
    private static func text(_ pieces: [Piece], tabStop: Float = 32) -> PreparedAttributedText {
        func lineEnd(_ piece: Piece) -> Float {
            switch piece.kind {
            case .text, .glue: return piece.width
            case .softHyphen: return piece.hyphen
            default: return 0
            }
        }
        var chunks: [PreparedLineChunk] = []
        var chunkStart = 0
        for (index, piece) in pieces.enumerated() where piece.kind == .hardBreak {
            chunks.append(
                PreparedLineChunk(
                    startSegmentIndex: chunkStart, endSegmentIndex: index,
                    consumedEndSegmentIndex: index + 1))
            chunkStart = index + 1
        }
        if chunkStart < pieces.count {
            chunks.append(
                PreparedLineChunk(
                    startSegmentIndex: chunkStart, endSegmentIndex: pieces.count,
                    consumedEndSegmentIndex: pieces.count))
        }
        let core = PreparedCore(
            widths: pieces.map(\.width),
            lineEndFitAdvances: pieces.map(lineEnd),
            lineEndPaintAdvances: pieces.map(lineEnd),
            kinds: pieces.map(\.kind),
            simpleLineWalkFastPath: false,
            breakableWidths: pieces.map { $0.graphemes.map { ContiguousArray($0) } },
            discretionaryHyphenWidth: 0,
            tabStopAdvance: tabStop,
            chunks: chunks
        )
        let lengths = pieces.map { $0.text.utf16.count }
        var starts: [Int] = []
        var offset = 0
        for length in lengths {
            starts.append(offset)
            offset += length
        }
        return PreparedAttributedText(
            core: core, segments: pieces.map(\.text), utf16Starts: starts,
            utf16Lengths: lengths,
            ascents: [Float](repeating: 0, count: pieces.count),
            descents: [Float](repeating: 0, count: pieces.count),
            sourceLength: offset
        )
    }

    /// The lines `layoutNextLine` steps through from the start, one at most for
    /// each UTF-16 unit, so a cursor that stops moving cannot hang the test.
    private static func lines(
        _ text: PreparedAttributedText, maxWidth: CGFloat, tabStop: CGFloat? = nil
    ) -> [LayoutLineRange] {
        var lines: [LayoutLineRange] = []
        var cursor = LayoutCursor.start
        while lines.count <= text.sourceLength,
            let line = layoutNextLine(
                text, start: cursor, maxWidth: maxWidth, tabStopAdvance: tabStop)
        {
            lines.append(line)
            cursor = line.end
        }
        return lines
    }

    /// The same line: the same cursors and the same width's bits.
    private static func same(_ a: LayoutLineRange?, _ b: LayoutLineRange) -> Bool {
        guard let a else { return false }
        return a.start == b.start && a.end == b.end
            && Float(a.width).bitPattern == Float(b.width).bitPattern
    }

    /// Widths on both sides of each finite bound of `line`, where the walker's
    /// limit, the width with the line-fit epsilon added, meets it.
    private static func crossings(_ line: LayoutLineRange) -> [CGFloat] {
        var widths: [CGFloat] = []
        for bound in [line.bounds.fitted, line.bounds.refused] where bound.isFinite {
            let meeting = CGFloat(bound - lineFitEpsilon)
            for delta: CGFloat in [-0.01, -0.001, -0.0001, 0, 0.0001, 0.001, 0.01] {
                widths.append(meeting + delta)
            }
        }
        return widths
    }

    /// A fixed list from 0.25 to 300 in quarter points.
    private static let grid: [CGFloat] = (1...1200).map { CGFloat($0) / 4 }

    /// For every line laid out at each of `references`, at the fixed widths and
    /// at the widths around its own bounds: whether its bounds hold, and whether
    /// a fresh walk from its start returns it. Returns the checks made and the
    /// widths at which the two answers differ, by reference width and line.
    private static func compare(
        _ text: PreparedAttributedText, at references: [CGFloat], tabStop: CGFloat? = nil
    ) -> (checks: Int, holdsButDiffers: [String], differsButNotHolds: [String]) {
        var checks = 0
        var holdsButDiffers: [String] = []
        var differsButNotHolds: [String] = []
        for reference in references {
            for (index, line) in lines(text, maxWidth: reference, tabStop: tabStop).enumerated() {
                #expect(line.holds(atMaxWidth: reference), "line \(index) holds at its width")
                for width in grid + crossings(line) {
                    let fresh = layoutNextLine(
                        text, start: line.start, maxWidth: width, tabStopAdvance: tabStop)
                    let holds = line.holds(atMaxWidth: width)
                    let isSame = same(fresh, line)
                    checks += 1
                    let at = "reference \(reference), line \(index), width \(width)"
                    if holds && !isSame { holdsButDiffers.append(at) }
                    if !holds && isSame { differsButNotHolds.append(at) }
                }
            }
        }
        return (checks, holdsButDiffers, differsButNotHolds)
    }

    /// Bounds hold exactly where a fresh walk returns the same line.
    private static func expectExact(
        _ text: PreparedAttributedText, at references: [CGFloat], tabStop: CGFloat? = nil,
        _ label: String
    ) {
        let result = compare(text, at: references, tabStop: tabStop)
        #expect(result.checks > 0, "\(label): checks made")
        #expect(result.holdsButDiffers.isEmpty, "\(label): \(result.holdsButDiffers.prefix(4))")
        #expect(
            result.differsButNotHolds.isEmpty, "\(label): \(result.differsButNotHolds.prefix(4))")
    }

    // MARK: - Texts

    /// Four words with a pre-wrap space of 4.5 after each but the last: a line
    /// that breaks after a space holds it past the edge.
    private static let spaced: [Piece] = [
        word("ab", 10.5), space(4.5), word("cdef", 21.25), space(4.5), word("ghij", 32),
        space(4.5), word("klmnop", 40.125),
    ]

    @Test("A trailing space that hangs past the edge, and spaces at the edge")
    func spaces() {
        let text = Self.text(Self.spaced)
        // At 36 the first line is the first word and its space, whose fit is
        // 10.5, and the second word refused at 36.25; at 36.25 the line takes
        // the second word and its space, which hangs 4.5 past the edge.
        let lines = Self.lines(text, maxWidth: 36)
        #expect(lines.first.map { [$0.bounds.fitted, $0.bounds.refused] } == [10.5, 36.25])
        Self.expectExact(text, at: [8, 10.5, 15, 36, 36.25, 40.75, 60, 117.375, 300], "spaces")
    }

    /// A tab, then four words with a tab after each but the last, on stops of 32.
    private static let tabbed: [Piece] = [
        Piece(text: "\t", kind: .tab, width: 0), word("ab", 10.5),
        Piece(text: "\t", kind: .tab, width: 0), word("cdef", 21.25),
        Piece(text: "\t", kind: .tab, width: 0), word("ghij", 32),
        Piece(text: "\t", kind: .tab, width: 0), word("klmnop", 40.125),
    ]

    @Test("Tabs, on the prepare's stop and on a stop the caller passes")
    func tabs() {
        let text = Self.text(Self.tabbed)
        Self.expectExact(text, at: [20, 42.5, 60, 100, 200, 1000], "tabs on stops of 32")
        Self.expectExact(text, at: [20, 60, 100, 1000], tabStop: 24, "tabs on stops of 24")
    }

    @Test("A hard break ends a line whatever the width")
    func hardBreak() {
        let text = Self.text([
            Self.word("ab", 10.5), Self.space(4.5), Self.word("cd", 10.5),
            Piece(text: "\n", kind: .hardBreak, width: 0),
            Self.word("efgh", 21.25), Self.space(4.5), Self.word("ij", 10.5),
        ])
        let wide = Self.lines(text, maxWidth: 100)
        #expect(wide.count == 2)
        #expect(wide.first?.bounds.refused == Float.infinity, "no comparison failed")
        Self.expectExact(text, at: [9, 12, 20, 25.5, 100], "hard break")
    }

    /// A word of ten graphemes of 5 each between two short words.
    private static let overlong: [Piece] = [
        word("ab", 10), space(5),
        word("abcdefghij", 50, graphemes: [Float](repeating: 5, count: 10)),
        space(5), word("cd", 10),
    ]

    @Test("An overlong word breaks inside itself, and a line starts inside it")
    func overlongWord() {
        let text = Self.text(Self.overlong)
        let lines = Self.lines(text, maxWidth: 22)
        #expect(lines.count > 3, "the word spans lines")
        #expect(lines.contains { $0.end.graphemeIndex > 0 }, "a line ends inside the word")
        #expect(lines.contains { $0.start.graphemeIndex > 0 }, "a line starts inside the word")
        Self.expectExact(text, at: [3, 7, 12, 22, 33, 48, 64.5, 200], "overlong word")
    }

    @Test("A soft hyphen fits with the hyphen's width")
    func softHyphen() {
        let text = Self.text([
            Self.word("hy", 10), Piece(text: "\u{AD}", kind: .softHyphen, width: 0, hyphen: 3),
            Self.word("phen", 20), Self.space(4), Self.word("ok", 10),
        ])
        let lines = Self.lines(text, maxWidth: 15)
        #expect(lines.first?.end == LayoutCursor(segmentIndex: 2, graphemeIndex: 0))
        #expect(lines.first.map { [$0.bounds.fitted, $0.bounds.refused] } == [13, 30])
        Self.expectExact(text, at: [9, 12, 15, 29, 31, 60], "soft hyphen")
    }

    @Test("A collapsible space that does not fit waits as the break")
    func collapsibleSpace() {
        let text = Self.text([
            Self.word("ab", 10), Piece(text: " ", kind: .space, width: 5), Self.word("cd", 10),
            Piece(text: " ", kind: .space, width: 5), Self.word("efgh", 20),
        ])
        Self.expectExact(text, at: [8, 12, 22, 27, 60], "collapsible space")
    }

    @Test("Mixed attribute runs, measured by the attributed prepare")
    func mixedRuns() {
        let body = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        let code = CTFontCreateWithName("Menlo" as CFString, 12, nil)
        let source = NSMutableAttributedString()
        let words = ["Mixed", "runs", "of", "words", "in", "two", "faces,", "a", "kern", "too."]
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let kernKey = NSAttributedString.Key(kCTKernAttributeName as String)
        for (index, word) in words.enumerated() {
            var attributes: [NSAttributedString.Key: Any] = [fontKey: index % 2 == 0 ? body : code]
            if word == "kern" { attributes[kernKey] = 1.5 }
            source.append(NSAttributedString(string: word, attributes: attributes))
            if index < words.count - 1 {
                source.append(NSAttributedString(string: " ", attributes: [fontKey: body]))
            }
        }
        let text = prepareAttributed(source)
        #expect(text.segmentCount == 2 * words.count - 1)
        Self.expectExact(text, at: [20, 45, 70, 110, 160, 400], "mixed runs")
    }

    // MARK: - Words in Pieces

    @Test("Two words with no break between them: the line holds wherever it is the same")
    func adjacentWords() {
        // "foo" and "(bar)" meet with no break opportunity, so past the space
        // the walk can take "foo" and still break at the space: at 30 the line
        // is the same as at 22, though "foo" now fits. The line at 22 holds up
        // to 50, where the walk takes "(bar)" too, and the line at 30 holds
        // down to 5, where the space still fits.
        let text = Self.text([
            Self.word("x", 5), Self.space(5), Self.word("foo", 15), Self.word("(bar)", 25),
            Self.space(5), Self.word("z", 5),
        ])
        let first = Self.lines(text, maxWidth: 22)[0]
        #expect(first.end == LayoutCursor(segmentIndex: 2, graphemeIndex: 0))
        #expect(first.bounds.refused == 50)
        #expect(first.holds(atMaxWidth: 30))
        #expect(Self.same(layoutNextLine(text, start: first.start, maxWidth: 30), first))
        let wide = Self.lines(text, maxWidth: 30)[0]
        #expect(wide.bounds.fitted == 5)
        #expect(wide.holds(atMaxWidth: 22))
        Self.expectExact(text, at: [8, 12, 22, 30, 45, 100], "adjacent words")
    }

    /// A word in three pieces with no break between them, as the segmenter can
    /// leave an identifier such as `w04_00001`, between two short words.
    private static let pieced: [Piece] = [
        word("ab", 10), space(5), word("cd", 10), word("_", 5), word("ef", 10), space(5),
        word("gh", 10),
    ]

    @Test("A word the walk takes in part and drops bounds the line on neither side")
    func droppedPieces() {
        // At 32 the walk takes "cd" and "_" past the space and refuses "ef", so
        // the line ends at the space: a narrower width that refuses "cd" or "_"
        // ends it there too, and only 40, which takes the whole word, moves it.
        let text = Self.text(Self.pieced)
        let line = Self.lines(text, maxWidth: 32)[0]
        #expect(line.end == LayoutCursor(segmentIndex: 2, graphemeIndex: 0))
        #expect([line.bounds.fitted, line.bounds.refused] == [10, 40])
        Self.expectExact(text, at: [9, 12, 26, 32, 39, 45, 100], "dropped pieces")
        // Before a soft hyphen the reach is the hyphen's own fit, 38: at 36 the
        // walk takes "cd" and "ef", refuses the hyphen and ends at the space.
        let hyphenated = Self.text([
            Self.word("ab", 10), Self.space(5), Self.word("cd", 10), Self.word("ef", 10),
            Piece(text: "\u{AD}", kind: .softHyphen, width: 0, hyphen: 3), Self.word("gh", 10),
        ])
        let cut = Self.lines(hyphenated, maxWidth: 22)[0]
        #expect([cut.bounds.fitted, cut.bounds.refused] == [10, 38])
        Self.expectExact(hyphenated, at: [9, 22, 30, 36, 40, 100], "pieces before a hyphen")
    }

    @Test("Identifiers through the attributed prepare, in the pieces it leaves them")
    func identifiers() {
        let code = CTFontCreateWithName("Menlo" as CFString, 12, nil)
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let words = (0..<8).map { String(format: "w%02d_%05d", $0, 1) }
        let source = NSAttributedString(
            string: words.joined(separator: " "), attributes: [fontKey: code])
        let text = prepareAttributed(source)
        #expect(text.segmentCount > 2 * words.count - 1, "an identifier is several pieces")
        Self.expectExact(text, at: [70, 100, 145, 150, 220, 290, 600], "identifiers")
    }

    // MARK: - The Bounds Themselves

    @Test("Bounds that compared nothing hold everywhere, `never` nowhere, a join where both do")
    func boundsAlgebra() {
        let widths: [CGFloat] = [-1, 0, 0.5, 10, 10.5, 36.25, 1000, .infinity]
        for width in widths {
            #expect(LineWidthBounds.always.holds(atMaxWidth: width), "always at \(width)")
            #expect(!LineWidthBounds.never.holds(atMaxWidth: width), "never at \(width)")
        }
        #expect(!LineWidthBounds.always.holds(atMaxWidth: .nan))
        let text = Self.text(Self.spaced)
        let lines = Self.lines(text, maxWidth: 36)
        #expect(lines.count > 2)
        let joined = lines.dropFirst().reduce(lines[0].bounds) { $0.joined(with: $1.bounds) }
        for width in Self.grid {
            #expect(
                joined.holds(atMaxWidth: width)
                    == lines.allSatisfy { $0.holds(atMaxWidth: width) }, "width \(width)")
        }
        #expect(lines[0].bounds.joined(with: .never) == .never)
        #expect(lines[0].bounds.joined(with: .always) == lines[0].bounds)
    }

    @Test("A line walked at no width limit holds there; the chunk walker's lines hold nowhere")
    func unlimitedAndChunkWalker() {
        let text = Self.text(Self.spaced)
        let unlimited = Self.lines(text, maxWidth: .infinity)
        #expect(unlimited.count == 1)
        #expect(unlimited.allSatisfy { $0.holds(atMaxWidth: .infinity) })
        #expect(unlimited.allSatisfy { $0.holds(atMaxWidth: 117.375) })
        #expect(unlimited.allSatisfy { !$0.holds(atMaxWidth: 117) })
        let face = FontDescriptor(CTFontCreateWithName("Helvetica" as CFString, 13, nil))
        let plain = prepareWithSegments("ab cdef ghij", font: face)
        var ranges: [LayoutLineRange] = []
        walkLineRanges(plain, maxWidth: 30) { ranges.append($0) }
        #expect(!ranges.isEmpty)
        #expect(ranges.allSatisfy { $0.bounds == .never && !$0.holds(atMaxWidth: 30) })
    }
}
