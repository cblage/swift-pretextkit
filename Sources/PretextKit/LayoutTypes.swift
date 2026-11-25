import CoreGraphics

// MARK: - Layout Result

/// The result of `layout()` — just line count and total height.
/// This is the cheap output of the arithmetic hot path.
public struct LayoutResult: Sendable {
    /// Number of lines the text wraps to at the given width.
    public let lineCount: Int
    /// Total height: `lineCount * lineHeight`.
    public let height: CGFloat

    public init(lineCount: Int, height: CGFloat) {
        self.lineCount = lineCount
        self.height = height
    }
}

// MARK: - Layout Cursor

/// A position within prepared text, expressed as segment + grapheme indices.
///
/// Used to track where a line starts and ends, and to resume iteration
/// with `layoutNextLine()`. The dual index is necessary because some
/// segments can break mid-grapheme (overflow-wrap, soft hyphens).
public struct LayoutCursor: Sendable, Equatable {
    /// Index into the segment array.
    public let segmentIndex: Int
    /// Index into the grapheme array within the segment (0 for whole-segment positions).
    public let graphemeIndex: Int

    public init(segmentIndex: Int, graphemeIndex: Int) {
        self.segmentIndex = segmentIndex
        self.graphemeIndex = graphemeIndex
    }

    /// The starting cursor (beginning of text).
    public static let start = LayoutCursor(segmentIndex: 0, graphemeIndex: 0)
}

// MARK: - Layout Line

/// A single laid-out line with its text content and cursor boundaries.
public struct LayoutLine: Sendable {
    /// The text content of this line.
    public let text: String
    /// The measured width of this line's content.
    public let width: CGFloat
    /// Cursor position at the start of this line.
    public let start: LayoutCursor
    /// Cursor position at the end of this line (start of next line).
    public let end: LayoutCursor
}

// MARK: - Layout Line Range

/// Like `LayoutLine` but without the text string — used by `walkLineRanges()`
/// to avoid the cost of text materialization when only geometry is needed.
public struct LayoutLineRange: Sendable {
    /// The measured width of this line's content.
    public let width: CGFloat
    /// Cursor position at the start of this line.
    public let start: LayoutCursor
    /// Cursor position at the end of this line.
    public let end: LayoutCursor
    /// The maximum widths at which a walk from `start` returns this line
    /// again. The attributed `layoutNextLine` keeps them; `walkLineRanges`
    /// keeps none, so its lines hold at no width.
    public let bounds: LineWidthBounds

    init(
        width: CGFloat, start: LayoutCursor, end: LayoutCursor,
        bounds: LineWidthBounds = .never
    ) {
        self.width = width
        self.start = start
        self.end = end
        self.bounds = bounds
    }

    /// Whether a walk from `start` at `maxWidth` returns this line: every
    /// comparison against the maximum width that decides it gives the same
    /// answer there.
    public func holds(atMaxWidth maxWidth: CGFloat) -> Bool {
        bounds.holds(atMaxWidth: maxWidth)
    }
}

// MARK: - Line Width Bounds

/// The maximum widths at which a line walk returns the same line. The walk
/// reads the maximum width only to compare a value of its own path against it,
/// with the line-fit epsilon, so it returns the same line at every maximum
/// width at which each comparison that decides the line gives the answer it
/// gave: `fitted` is the greatest value found within the width, and `refused`
/// the least value found past it. For a line that ends at its last break, the
/// segments the walk took past that break and dropped decide nothing, and
/// `refused` is no greater than the walk's reach past the break
/// (`walkSingleLine`).
public struct LineWidthBounds: Sendable, Equatable {
    /// The greatest value a comparison found within the maximum width;
    /// negative infinity when none did.
    public private(set) var fitted: Float
    /// The least value a comparison found past the maximum width; infinity
    /// when none did.
    public private(set) var refused: Float

    init(fitted: Float, refused: Float) {
        self.fitted = fitted
        self.refused = refused
    }

    /// A walk that compared nothing: the same path at every maximum width.
    public static let always = LineWidthBounds(fitted: -.infinity, refused: .infinity)

    /// A walk whose comparisons were not kept: it holds at no maximum width.
    public static let never = LineWidthBounds(fitted: .infinity, refused: -.infinity)

    /// The bounds of walks made at one maximum width: they hold where each holds.
    public func joined(with other: LineWidthBounds) -> LineWidthBounds {
        LineWidthBounds(fitted: max(fitted, other.fitted), refused: min(refused, other.refused))
    }

    /// Whether every comparison gives the answer it gave at `maxWidth`, by the
    /// walker's own arithmetic: a value fits when it is no greater than the
    /// width with the line-fit epsilon added.
    public func holds(atMaxWidth maxWidth: CGFloat) -> Bool {
        let limit = Float(maxWidth) + lineFitEpsilon
        return fitted <= limit && (refused == .infinity || limit < refused)
    }

    /// The walker's fit test, folded: whether `value` is no greater than the
    /// maximum width with the line-fit epsilon added.
    mutating func fits(_ value: Float, within maxWidth: Float) -> Bool {
        let fits = value <= maxWidth + lineFitEpsilon
        fold(value, fits: fits)
        return fits
    }

    /// The walker's overflow test, folded: whether `value` is greater than the
    /// maximum width with the line-fit epsilon added.
    mutating func overflows(_ value: Float, past maxWidth: Float) -> Bool {
        let overflows = value > maxWidth + lineFitEpsilon
        fold(value, fits: !overflows)
        return overflows
    }

    /// A value that fit raises `fitted`, and one that did not lowers `refused`.
    /// A NaN answers the same at every width, and `max` and `min` pass over it.
    private mutating func fold(_ value: Float, fits: Bool) {
        if fits {
            fitted = max(fitted, value)
        } else {
            refused = min(refused, value)
        }
    }
}

// MARK: - Layout Lines Result

/// Full result of `layoutWithLines()` — line count, height, and all lines.
public struct LayoutLinesResult: Sendable {
    public let lineCount: Int
    public let height: CGFloat
    public let lines: [LayoutLine]
}
