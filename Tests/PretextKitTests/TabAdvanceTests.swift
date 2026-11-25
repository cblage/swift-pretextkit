import CoreGraphics
import Testing

@testable import PretextKit

/// The tab advance, and the line walkers that take it for a tab piece.
///
/// The prepared texts are built from pieces whose widths are exact in binary,
/// so each expected width follows by hand from the tab formula: a tab takes a
/// line to its next multiple of the tab stop, or one whole stop on from a line
/// that stands on a stop.
@Suite("Tab advance")
struct TabAdvanceTests {

    // MARK: - Helpers

    private typealias Piece = (text: String, kind: SegmentBreakKind, width: Float)

    /// One laid-out line: the cursors it starts and ends at, and its width's bits.
    private struct Line: Equatable, CustomStringConvertible {
        let start: LayoutCursor
        let end: LayoutCursor
        let widthBits: UInt32

        init(_ start: LayoutCursor, _ end: LayoutCursor, width: CGFloat) {
            self.start = start
            self.end = end
            widthBits = Float(width).bitPattern
        }

        /// A line over the whole pieces `start..<end`.
        init(_ start: Int, _ end: Int, _ width: Float) {
            self.start = LayoutCursor(segmentIndex: start, graphemeIndex: 0)
            self.end = LayoutCursor(segmentIndex: end, graphemeIndex: 0)
            widthBits = width.bitPattern
        }

        var description: String {
            "\(start.segmentIndex).\(start.graphemeIndex) to \(end.segmentIndex)."
                + "\(end.graphemeIndex), width \(Float(bitPattern: widthBits))"
        }
    }

    /// The prepared core of hand-measured pieces in one chunk. A tab and a
    /// pre-wrap space add nothing to a line's width at its end, as both
    /// prepares measure them, and no piece breaks inside itself. Both kinds
    /// keep a prepare off the simple line counter, so `layout` counts lines
    /// with the chunk counter.
    private static func core(_ pieces: [Piece], tabStop: Float) -> PreparedCore {
        let lineEnd = pieces.map { $0.kind == .text ? $0.width : 0 }
        return PreparedCore(
            widths: pieces.map { $0.width },
            lineEndFitAdvances: lineEnd,
            lineEndPaintAdvances: lineEnd,
            kinds: pieces.map { $0.kind },
            simpleLineWalkFastPath: false,
            breakableWidths: [ContiguousArray<Float>?](repeating: nil, count: pieces.count),
            discretionaryHyphenWidth: 0,
            tabStopAdvance: tabStop,
            chunks: [
                PreparedLineChunk(
                    startSegmentIndex: 0, endSegmentIndex: pieces.count,
                    consumedEndSegmentIndex: pieces.count)
            ]
        )
    }

    private static func plainText(_ pieces: [Piece], tabStop: Float) -> PreparedTextWithSegments {
        PreparedTextWithSegments(
            core: core(pieces, tabStop: tabStop), segments: pieces.map { $0.text })
    }

    private static func attributedText(
        _ pieces: [Piece], tabStop: Float
    ) -> PreparedAttributedText {
        let lengths = pieces.map { $0.text.utf16.count }
        var starts: [Int] = []
        var offset = 0
        for length in lengths {
            starts.append(offset)
            offset += length
        }
        return PreparedAttributedText(
            core: core(pieces, tabStop: tabStop), segments: pieces.map { $0.text },
            utf16Starts: starts, utf16Lengths: lengths,
            ascents: [Float](repeating: 0, count: pieces.count),
            descents: [Float](repeating: 0, count: pieces.count),
            sourceLength: offset
        )
    }

    /// The lines `layoutNextLine` steps through, one at most for each piece,
    /// so a cursor that stops moving fails the comparison instead of hanging.
    private static func steppedLines(
        _ text: PreparedTextWithSegments, maxWidth: CGFloat
    ) -> [Line] {
        var lines: [Line] = []
        var cursor = LayoutCursor.start
        while lines.count < text.segments.count,
            let line = layoutNextLine(text, start: cursor, maxWidth: maxWidth)
        {
            lines.append(Line(line.start, line.end, width: line.width))
            cursor = line.end
        }
        return lines
    }

    /// The same steps through the attributed entry, with its tab stop override.
    private static func steppedAttributedLines(
        _ text: PreparedAttributedText, maxWidth: CGFloat, tabStop: CGFloat?
    ) -> [Line] {
        var lines: [Line] = []
        var cursor = LayoutCursor.start
        while lines.count < text.segmentCount,
            let line = layoutNextLine(
                text, start: cursor, maxWidth: maxWidth, tabStopAdvance: tabStop)
        {
            lines.append(Line(line.start, line.end, width: line.width))
            cursor = line.end
        }
        return lines
    }

    /// The lines of the chunk walker, through `walkLineRanges`.
    private static func rangeLines(_ text: PreparedTextWithSegments, maxWidth: CGFloat) -> [Line] {
        var lines: [Line] = []
        walkLineRanges(text, maxWidth: maxWidth) { line in
            lines.append(Line(line.start, line.end, width: line.width))
        }
        return lines
    }

    // MARK: - Tab Advance

    @Test("A tab advances a line to its next stop, a whole stop from a stop, bit for bit")
    func tabAdvanceTable() {
        // Each advance is the formula's value: zero for a tab stop of 0 or
        // less, a whole stop for a remainder within 1e-6, else the stop less
        // the remainder, which takes the sign of a negative line width.
        let table: [(lineW: Float, tabStop: Float, advance: Float)] = [
            (0, 8, 8),
            (8, 8, 8),
            (24, 8, 8),
            (Float(8).nextDown, 8, 0x1p-21),
            (Float(8).nextUp, 8, 8),  // a remainder of 0x1p-20 is within 1e-6
            (1e-6, 8, 8),
            (70.5, 35.25, 35.25),
            (Float(70.5).nextDown, 35.25, 0x1p-17),
            (Float(70.5).nextUp, 35.25, 35.25 - 0x1p-17),  // a remainder of 0x1p-17
            (10.5, 32, 21.5),
            (53.25, 32, 10.75),
            (1000.5, 35.25, 21.75),
            (-3, 8, 11),
            (-10.5, 8, 10.5),
            (-8, 8, 8),  // a remainder of -0
            (5, 0, 0),
            (0, 0, 0),
            (5, -8, 0),
        ]
        for row in table {
            let advance = getTabAdvance(lineW: row.lineW, tabStopAdvance: row.tabStop)
            #expect(
                advance.bitPattern == row.advance.bitPattern,
                "line width \(row.lineW), tab stop \(row.tabStop): \(advance)")
        }
    }

    // MARK: - Lines With Tabs

    /// A tab, then four words with a tab after each but the last, on stops of
    /// 32: a whole stop to 32, "ab" to 42.5, a tab to 64, "cdef" to 85.25, a
    /// tab to 96, "ghij" to 128 on a stop, a whole stop to 160, and "klmnop"
    /// to 200.125.
    private static let tabbed: [Piece] = [
        ("\t", .tab, 0), ("ab", .text, 10.5), ("\t", .tab, 0), ("cdef", .text, 21.25),
        ("\t", .tab, 0), ("ghij", .text, 32), ("\t", .tab, 0), ("klmnop", .text, 40.125),
    ]

    @Test("Text with tabs breaks at the same pieces with the same widths in every walker")
    func tabbedLines() {
        let plain = Self.plainText(Self.tabbed, tabStop: 32)
        let attributed = Self.attributedText(Self.tabbed, tabStop: 32)
        // A line that breaks after a tab is as wide as the stop that tab reached.
        let cases: [(maxWidth: CGFloat, lines: [Line])] = [
            (1000, [Line(0, 8, 200.125)]),
            (200.125, [Line(0, 8, 200.125)]),
            (200, [Line(0, 7, 160), Line(7, 8, 40.125)]),
            (100, [Line(0, 5, 96), Line(5, 7, 64), Line(7, 8, 40.125)]),
            (60, [Line(0, 3, 64), Line(3, 5, 32), Line(5, 7, 64), Line(7, 8, 40.125)]),
        ]
        for (maxWidth, lines) in cases {
            #expect(Self.steppedLines(plain, maxWidth: maxWidth) == lines, "width \(maxWidth)")
            #expect(
                Self.steppedAttributedLines(attributed, maxWidth: maxWidth, tabStop: nil)
                    == lines, "width \(maxWidth)")
            #expect(Self.rangeLines(plain, maxWidth: maxWidth) == lines, "width \(maxWidth)")
            #expect(
                layout(plain, maxWidth: maxWidth, lineHeight: 1).lineCount == lines.count,
                "width \(maxWidth)")
        }
    }

    @Test("A tab stop passed to the attributed walk governs where each tab lands")
    func tabStopOverride() {
        let attributed = Self.attributedText(Self.tabbed, tabStop: 32)
        // On stops of 24: a whole stop to 24, "ab" to 34.5, a tab to 48, "cdef"
        // to 69.25, a tab to 72, "ghij" to 104, a tab to 120, "klmnop" to 160.125.
        let cases: [(maxWidth: CGFloat, lines: [Line])] = [
            (1000, [Line(0, 8, 160.125)]),
            (60, [Line(0, 3, 48), Line(3, 7, 72), Line(7, 8, 40.125)]),
        ]
        for (maxWidth, lines) in cases {
            #expect(
                Self.steppedAttributedLines(attributed, maxWidth: maxWidth, tabStop: 24)
                    == lines, "width \(maxWidth)")
        }
    }

    // MARK: - Lines Without Tabs

    /// The same words with a pre-wrap space of 4.5 after each but the last, and
    /// no tab: 10.5, 15, 36.25, 40.75, 72.75, 77.25, then 117.375.
    private static let spaced: [Piece] = [
        ("ab", .text, 10.5), (" ", .preservedSpace, 4.5), ("cdef", .text, 21.25),
        (" ", .preservedSpace, 4.5), ("ghij", .text, 32), (" ", .preservedSpace, 4.5),
        ("klmnop", .text, 40.125),
    ]

    @Test("Text with no tab breaks at the same pieces with the same widths in every walker")
    func untabbedLines() {
        let plain = Self.plainText(Self.spaced, tabStop: 36)
        let attributed = Self.attributedText(Self.spaced, tabStop: 36)
        // A line that breaks after a space is as wide as its words and that space.
        let cases: [(maxWidth: CGFloat, lines: [Line])] = [
            (1000, [Line(0, 7, 117.375)]),
            (60, [Line(0, 4, 40.75), Line(4, 6, 36.5), Line(6, 7, 40.125)]),
            (36, [Line(0, 2, 15), Line(2, 4, 25.75), Line(4, 6, 36.5), Line(6, 7, 40.125)]),
        ]
        for (maxWidth, lines) in cases {
            #expect(Self.steppedLines(plain, maxWidth: maxWidth) == lines, "width \(maxWidth)")
            #expect(
                Self.steppedAttributedLines(attributed, maxWidth: maxWidth, tabStop: nil)
                    == lines, "width \(maxWidth)")
            #expect(Self.rangeLines(plain, maxWidth: maxWidth) == lines, "width \(maxWidth)")
            #expect(
                layout(plain, maxWidth: maxWidth, lineHeight: 1).lineCount == lines.count,
                "width \(maxWidth)")
        }
    }
}
