import CoreText
import Foundation
import Testing
import os

@testable import PretextKit

@Suite("Attributed measurement memo", .serialized)
struct AttributedMeasurementMemoTests {
    private static let fontKey = NSAttributedString.Key("NSFont")
    private static let kernKey = NSAttributedString.Key("NSKern")

    private final class LineCounter {
        var builds: [String: Int] = [:]
        var count: Int { builds.values.reduce(0, +) }

        func makeLine(_ text: CFAttributedString) -> CTLine {
            builds[CFAttributedStringGetString(text) as String, default: 0] += 1
            return CTLineCreateWithAttributedString(text)
        }
    }

    private static func attributes(_ font: CTFont?, _ kern: NSNumber? = nil)
        -> [NSAttributedString.Key: Any]
    {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let font { attributes[fontKey] = font }
        if let kern { attributes[kernKey] = kern }
        return attributes
    }

    private func bits(_ metrics: AttributedSegmentMeasurer.Metrics) -> [UInt32] {
        [metrics.width.bitPattern, metrics.ascent.bitPattern, metrics.descent.bitPattern]
    }

    private func originalBits(_ source: NSAttributedString) -> [UInt32] {
        let line = CTLineCreateWithAttributedString(source as CFAttributedString)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        return [Float(width).bitPattern, Float(ascent).bitPattern, Float(descent).bitPattern]
    }

    @Test("Every spelling, font object and kern reproduces all three CoreText metrics")
    func metricBits() throws {
        let system = try #require(CTFontCreateUIFontForLanguage(.system, 18, nil))
        let axes = try #require(CTFontCopyVariationAxes(system) as? [[CFString: Any]])
        let weight = NSNumber(value: 0x7767_6874)  // OpenType 'wght'
        let axis = try #require(
            axes.first { $0[kCTFontVariationAxisIdentifierKey] as? NSNumber == weight })
        let low = try #require(axis[kCTFontVariationAxisMinimumValueKey] as? NSNumber)
        let high = try #require(axis[kCTFontVariationAxisMaximumValueKey] as? NSNumber)
        #expect(low.doubleValue < high.doubleValue)
        let descriptor = CTFontCopyFontDescriptor(system)
        func systemWeight(_ value: NSNumber) -> CTFont {
            let variant = CTFontDescriptorCreateCopyWithVariation(
                descriptor, weight, CGFloat(value.doubleValue))
            return CTFontCreateWithFontDescriptor(variant, 18, nil)
        }
        let light = systemWeight(low)
        let heavy = systemWeight(high)
        #expect(
            CTFontCopyVariation(light) as NSDictionary? != CTFontCopyVariation(heavy)
                as NSDictionary?)
        var matrix = CGAffineTransform(scaleX: 1.5, y: 1)
        let fonts: [CTFont?] = [
            nil, light, heavy, CTFontCreateCopyWithAttributes(heavy, 18, &matrix, nil),
            CTFontCreateWithName("Helvetica" as CFString, 12, nil),
            CTFontCreateWithName("Helvetica" as CFString, 24, nil),
            CTFontCreateWithName("Helvetica-Oblique" as CFString, 18, nil),
        ]
        let spellings = ["AV", "office", "é", "e\u{301}", "漢字", "👩🏽‍💻", "مرحبا", "שָׁלוֹם"]
        let kerns: [NSNumber?] = [nil, 0, -0.75, 1.25]
        let memo = AttributedMeasurementMemo(byteLimit: 1 << 20)
        let counter = LineCounter()
        for font in fonts {
            for kern in kerns {
                for text in spellings {
                    let source = NSAttributedString(
                        string: text, attributes: Self.attributes(font, kern))
                    let range = NSRange(location: 0, length: source.length)
                    let uncached = AttributedSegmentMeasurer(
                        source: source, memo: .init(byteLimit: 0))
                    let cached = AttributedSegmentMeasurer(
                        source: source, memo: memo, makeLine: counter.makeLine)
                    let expected = originalBits(source)
                    #expect(bits(uncached.measure(range, text: text)) == expected)
                    #expect(bits(cached.measure(range, text: text)) == expected)
                    #expect(bits(cached.measure(text, fontAt: 0)) == expected)
                    #expect(bits(cached.measure(range, text: text)) == expected)
                }
            }
        }
        #expect(counter.builds.values.reduce(0, +) == fonts.count * kerns.count * spellings.count)
    }

    private static func mixedDocument() -> NSAttributedString {
        let body = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        let italic = CTFontCreateWithName("Helvetica-Oblique" as CFString, 24, nil)
        let text = NSMutableAttributedString(string: "")
        func append(_ string: String, _ font: CTFont, _ kern: NSNumber? = nil) {
            text.append(NSAttributedString(string: string, attributes: attributes(font, kern)))
        }
        append("mixed kerning mix", body)
        append("ed", italic)
        append(" ker", body)
        append("ning", body, 3)
        append("\t\u{fffc} 漢字 👩🏽‍💻 e\u{301} مرحبا שָׁלוֹם\n", body)
        append("soft\u{ad}hyphen non\u{a0}breaking\u{200b}\u{fffc} ", italic)
        append(String(repeating: "ab", count: 30), body)
        return text
    }

    private static func attachment(at location: Int) -> AttachmentMetrics? {
        let first = ("mixed kerning mixed kerning\t" as NSString).length
        return location == first ? AttachmentMetrics(width: 37.5, ascent: 28, descent: 7.5) : nil
    }

    private func expectSame(_ actual: PreparedAttributedText, _ expected: PreparedAttributedText) {
        #expect(actual.sourceLength == expected.sourceLength)
        #expect(actual.segments.map { Array($0.utf8) } == expected.segments.map { Array($0.utf8) })
        #expect(actual.utf16Starts == expected.utf16Starts)
        #expect(actual.utf16Lengths == expected.utf16Lengths)
        #expect(actual.kinds == expected.kinds)
        #expect(actual.widths.map(\.bitPattern) == expected.widths.map(\.bitPattern))
        #expect(actual.ascents.map(\.bitPattern) == expected.ascents.map(\.bitPattern))
        #expect(actual.descents.map(\.bitPattern) == expected.descents.map(\.bitPattern))
        let a = actual.core
        let b = expected.core
        #expect(a.lineEndFitAdvances.map(\.bitPattern) == b.lineEndFitAdvances.map(\.bitPattern))
        #expect(
            a.lineEndPaintAdvances.map(\.bitPattern) == b.lineEndPaintAdvances.map(\.bitPattern))
        #expect(
            a.breakableWidths.map { $0?.map(\.bitPattern) }
                == b.breakableWidths.map { $0?.map(\.bitPattern) })
        #expect(a.discretionaryHyphenWidth.bitPattern == b.discretionaryHyphenWidth.bitPattern)
        #expect(a.tabStopAdvance.bitPattern == b.tabStopAdvance.bitPattern)
        #expect(a.simpleLineWalkFastPath == b.simpleLineWalkFastPath)
        #expect(a.chunks.map(\.startSegmentIndex) == b.chunks.map(\.startSegmentIndex))
        #expect(a.chunks.map(\.endSegmentIndex) == b.chunks.map(\.endSegmentIndex))
        #expect(a.chunks.map(\.consumedEndSegmentIndex) == b.chunks.map(\.consumedEndSegmentIndex))
    }

    @Test("Cold and warm mixed documents reproduce the uncached prepare, including attachments")
    func mixedPrepare() throws {
        let source = Self.mixedDocument()
        let uncached = AttributedSegmentMeasurer(source: source, memo: .init(byteLimit: 0))
        let expected = prepareAttributed(
            source, attachmentMetrics: Self.attachment, measurer: uncached)
        let firstAttachment = try #require(expected.segments.firstIndex(of: "\u{fffc}"))
        #expect(expected.widths[firstAttachment] == 37.5)
        #expect(expected.ascents[firstAttachment] == 28)
        #expect(expected.descents[firstAttachment] == 7.5)
        let memo = AttributedMeasurementMemo(byteLimit: 1 << 20)
        let cold = prepareAttributed(
            source, attachmentMetrics: Self.attachment,
            measurer: AttributedSegmentMeasurer(source: source, memo: memo)
        )
        expectSame(cold, expected)
        let counter = LineCounter()
        let warm = prepareAttributed(
            source, attachmentMetrics: Self.attachment,
            measurer: AttributedSegmentMeasurer(
                source: source, memo: memo, makeLine: counter.makeLine)
        )
        expectSame(warm, expected)
        #expect(counter.builds == ["mixed": 1, "kerning": 1])
        expectSame(prepareAttributed(source, attachmentMetrics: Self.attachment), expected)
    }

    @Test("Mixed runs and attachments keep every metric across a mid-document eviction")
    func evictionDuringPrepare() {
        let font = CTFontCreateWithName("Menlo" as CFString, 17, nil)
        let block = NSMutableAttributedString(
            string: "echo echo ", attributes: Self.attributes(font, -0.75))
        block.append(Self.mixedDocument())
        let source = NSMutableAttributedString(attributedString: block)
        source.append(NSAttributedString(string: " \u{fffc} "))
        let middle = block.length + 1
        source.append(block)
        func attachment(_ location: Int) -> AttachmentMetrics {
            AttachmentMetrics(width: CGFloat(11 + location % 31), ascent: 12, descent: 3)
        }
        let disabled = AttributedMeasurementMemo(byteLimit: 0)
        let expected = prepareAttributed(
            source, attachmentMetrics: attachment,
            measurer: AttributedSegmentMeasurer(source: source, memo: disabled))
        let limit = 16 << 10
        let memo = AttributedMeasurementMemo(byteLimit: limit)
        let counter = LineCounter()
        let oversized = String(repeating: "x", count: limit)
        var clears = 0
        let actual = prepareAttributed(
            source,
            attachmentMetrics: { location in
                if location == middle {
                    _ = memo.measure(oversized, style: .init(font: nil, kern: nil)) {
                        .init(width: 0, ascent: 0, descent: 0)
                    }
                    clears += 1
                }
                return attachment(location)
            },
            measurer: AttributedSegmentMeasurer(
                source: source, memo: memo, makeLine: counter.makeLine))
        #expect(!disabled.isEnabled && memo.isEnabled)
        #expect(clears == 1)
        #expect(counter.builds["echo"] == 2)
        expectSame(actual, expected)
        for i in actual.segments.indices
        where actual.kinds[i] == .text && actual.segments[i] != "\u{fffc}" {
            let range = NSRange(location: actual.utf16Starts[i], length: actual.utf16Lengths[i])
            let metrics = [actual.widths[i], actual.ascents[i], actual.descents[i]]
            let original = source.attributedSubstring(from: range)
            #expect(metrics.map(\.bitPattern) == originalBits(original))
        }
    }

    @Test("Only one source-font owner survives a lookup and eviction releases both fonts")
    func fontOwnership() throws {
        typealias Style = AttributedMeasurementMemo.Style
        let font = CTFontCreateWithName("Helvetica" as CFString, 17.125, nil)
        let kern = NSNumber(value: 0.375_001_234_567_89)
        let source = NSAttributedString(string: "word", attributes: Self.attributes(font, kern))
        let borrowed = Unmanaged.passUnretained(font)
        let borrowedKern = Unmanaged.passUnretained(kern)
        let address = UnsafeRawPointer(borrowed.toOpaque())
        func references() -> CFIndex {
            borrowed._withUnsafeGuaranteedRef { CFGetRetainCount($0) }
        }
        func kernReferences() -> CFIndex {
            borrowedKern._withUnsafeGuaranteedRef { CFGetRetainCount($0) }
        }
        let style = try #require(Style(font: address, kern: kern))
        // A trivial optional has no ARC operations even for copies destroyed inside a hit.
        #expect(_isPOD(Style?.self))
        let limit = 4096
        let memo = AttributedMeasurementMemo(byteLimit: limit)
        var inLine: [[CFIndex]] = []
        let measurer = AttributedSegmentMeasurer(source: source, memo: memo) { scratch in
            inLine.append([references(), kernReferences()])
            return CTLineCreateWithAttributedString(scratch)
        }
        withExtendedLifetime((font, kern, source)) {
            let before = references()
            let beforeKern = kernReferences()
            var misses: [CFIndex] = []
            for word in ["word", "other", "word"] {
                _ = memo.measure(word, style: style) {
                    misses.append(references())
                    return .init(width: 7, ascent: 3, descent: 1)
                }
                #expect(references() == before + 1)
            }
            let hit = measurer.measure(
                NSRange(location: 0, length: source.length), text: source.string)
            #expect(hit.width == 7 && inLine.isEmpty)
            #expect(misses == [before + 1, before + 1])
            #expect(references() == before + 1)
            #expect(kernReferences() == beforeKern)
            autoreleasepool { _ = measurer.measure("unseen", fontAt: 0) }
            #expect(inLine == [[before + 1, beforeKern]])
            let copy = memo.measurementFont(for: address)
            let copyCount = CFGetRetainCount(copy)
            _ = memo.measure(String(repeating: "x", count: limit), style: style) {
                #expect(references() == before)
                return .init(width: 1, ascent: 1, descent: 0)
            }
            #expect(references() == before)
            #expect(CFGetRetainCount(copy) == copyCount - 1)
            let rebuilt = memo.measure("word", style: style) {
                AttributedSegmentMeasurer.Metrics(width: 9, ascent: 3, descent: 1)
            }
            #expect(rebuilt.width == 9)
            #expect(memo.measurementFont(for: address) !== copy)
        }
    }

    @Test(
        "Two live lines use private fonts for both explicit and default faces",
        arguments: [false, true], [false, true])
    func workerFontCopies(explicitFont: Bool, withKern: Bool) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 19.25, nil)
        let source = NSAttributedString(
            string: "office",
            attributes: Self.attributes(explicitFont ? font : nil, withKern ? 0.5 : nil))
        let expected = originalBits(source)
        let ready = DispatchGroup()
        let finished = DispatchGroup()
        typealias Output = (
            scratch: ObjectIdentifier?, glyphs: ObjectIdentifier?, metrics: [UInt32]
        )
        let results = OSAllocatedUnfairLock(initialState: [Output]())
        ready.enter()
        ready.enter()
        for _ in 0..<2 {
            finished.enter()
            Thread.detachNewThread {
                var scratchFont: ObjectIdentifier?
                var glyphFont: ObjectIdentifier?
                var reachedLine = false
                let measurer = AttributedSegmentMeasurer(source: source) { scratch in
                    let input = CFAttributedStringGetAttribute(
                        scratch, 0, kCTFontAttributeName, nil)
                    scratchFont = input.map(ObjectIdentifier.init)
                    let line = CTLineCreateWithAttributedString(scratch)
                    let runs = CTLineGetGlyphRuns(line)
                    if CFArrayGetCount(runs) > 0, let first = CFArrayGetValueAtIndex(runs, 0) {
                        let run = Unmanaged<CTRun>.fromOpaque(first).takeUnretainedValue()
                        let attrs = CTRunGetAttributes(run) as NSDictionary
                        glyphFont = attrs[kCTFontAttributeName].map {
                            ObjectIdentifier($0 as AnyObject)
                        }
                    }
                    if !reachedLine {
                        reachedLine = true
                        ready.leave()
                        ready.wait()
                    }
                    return line
                }
                let metrics = measurer.measure(
                    NSRange(location: 0, length: source.length), text: source.string)
                if !reachedLine { ready.leave() }
                let result: Output = (scratchFont, glyphFont, bits(metrics))
                results.withLock { $0.append(result) }
                finished.leave()
            }
        }
        finished.wait()
        let outputs = results.withLock { $0 }
        #expect(outputs.count == 2)
        #expect(Set(outputs.compactMap(\.scratch)).count == 2)
        for output in outputs {
            #expect(output.scratch != ObjectIdentifier(font))
            #expect(output.glyphs == output.scratch)
            #expect(output.metrics == expected)
        }
    }

    @Test("A prepare computes one style per run, including runs inside overlong words")
    func stylesPerRun() throws {
        let body = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        let italic = CTFontCreateWithName("Helvetica-Oblique" as CFString, 23, nil)
        let prefix = "red red\t"
        let word = String(repeating: "abe\u{301}", count: 12)
        let source = NSMutableAttributedString(
            string: "\(prefix)\(word) \(word)\nred", attributes: Self.attributes(body))
        // Both boundaries split a grapheme. Only the second word changes measurement style.
        let decoration = NSRange(location: prefix.utf16.count + 11, length: 16)
        let mixed = NSRange(location: decoration.location + word.utf16.count + 1, length: 16)
        source.addAttribute(.init("Decoration"), value: 1, range: decoration)
        source.addAttributes(Self.attributes(italic, 1.25), range: mixed)
        let range = NSRange(location: 0, length: source.length)
        var runCount = 0
        source.enumerateAttributes(in: range) { _, _, _ in runCount += 1 }
        #expect(runCount == 5)

        let uncached = LineCounter()
        let expected = prepareAttributed(
            source,
            measurer: AttributedSegmentMeasurer(
                source: source, memo: .init(byteLimit: 0), makeLine: uncached.makeLine))
        let words = expected.segments.indices.filter { expected.segments[$0] == word }
        #expect(words.count == 2)
        for index in words {
            #expect(try #require(expected.core.breakableWidths[index]).count == word.count)
        }

        let memo = AttributedMeasurementMemo(byteLimit: 1 << 20)
        let cold = LineCounter()
        let warm = LineCounter()
        for counter in [cold, warm] {
            var styles = 0
            let measurer = AttributedSegmentMeasurer(
                source: source, memo: memo, makeLine: counter.makeLine,
                makeStyle: { font, kern in
                    styles += 1
                    return .init(font: font, kern: kern)
                })
            expectSame(prepareAttributed(source, measurer: measurer), expected)
            #expect(styles == runCount)
        }
        #expect(cold.count == 13)
        #expect(warm.count == 3)
        // Only mixed styles build lines on the warm pass.
        // Each other measurement accounts for one dictionary lookup.
        #expect(uncached.count - warm.count == 80)
    }

    @Test("Equal-length canonical spellings have separate entries and empty text can hit")
    func exactUTF8Keys() {
        let first = "a\u{301}\u{327}"
        let second = "a\u{327}\u{301}"
        #expect(first == second)
        #expect(first.utf8.count == second.utf8.count)
        let counter = LineCounter()
        let measurer = AttributedSegmentMeasurer(
            source: NSAttributedString(string: "x"), memo: .init(byteLimit: 1 << 20),
            makeLine: counter.makeLine)
        for text in [first, second, "", first, second, ""] {
            _ = measurer.measure(text, fontAt: 0)
        }
        #expect(counter.count == 3)
    }

    @Test("Only CF numbers supply kern bits, including the sign of zero")
    func kernBits() throws {
        typealias Style = AttributedMeasurementMemo.Style
        let absent = try #require(Style(font: nil, kern: nil))
        let positive = try #require(Style(font: nil, kern: NSNumber(value: 0.0)))
        let negative = try #require(Style(font: nil, kern: NSNumber(value: -0.0)))
        #expect(absent != positive)
        #expect(positive != negative)
        #expect(negative.kernBits == (-0.0 as Double).bitPattern)
        #expect(Style(font: nil, kern: kCFBooleanTrue) == nil)
        #expect(Style(font: nil, kern: "1" as NSString) == nil)
        #expect(Style(font: nil, kern: LineCounter()) == nil)
    }

    @Test("Ten copies of each word build one CoreText line for each word, font and kern")
    func repeatedWords() {
        let regular = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        let bold = CTFontCreateWithName("Helvetica-Bold" as CFString, 16, nil)
        let source = NSMutableAttributedString(string: "")
        for i in 0..<10 {
            if i > 0 {
                source.append(NSAttributedString(string: " ", attributes: Self.attributes(regular)))
            }
            let font = i.isMultiple(of: 2) ? regular : bold
            source.append(NSAttributedString(string: "swift", attributes: Self.attributes(font)))
            source.append(NSAttributedString(string: " ", attributes: Self.attributes(regular)))
            let kern: NSNumber? = i.isMultiple(of: 2) ? nil : 0
            source.append(
                NSAttributedString(string: "type", attributes: Self.attributes(regular, kern)))
            source.append(NSAttributedString(string: " font", attributes: Self.attributes(regular)))
            source.addAttribute(
                .init("Decoration"), value: i,
                range: NSRange(location: source.length - 2, length: 1))
        }
        let baseline = LineCounter()
        let expected = prepareAttributed(
            source,
            measurer: AttributedSegmentMeasurer(
                source: source, memo: .init(byteLimit: 0), makeLine: baseline.makeLine)
        )
        #expect(baseline.builds == ["swift": 10, "type": 10, "font": 10, " ": 30, "-": 1])

        let memo = AttributedMeasurementMemo(byteLimit: 1 << 20)
        let counter = LineCounter()
        for _ in 0..<2 {
            let measurer = AttributedSegmentMeasurer(
                source: source, memo: memo, makeLine: counter.makeLine)
            expectSame(prepareAttributed(source, measurer: measurer), expected)
            #expect(counter.builds == ["swift": 2, "type": 2, "font": 1, " ": 1, "-": 1])
        }
    }

    @Test("Overlong words reuse each distinct grapheme")
    func graphemeWidths() throws {
        let word = String(repeating: "ab", count: 30)
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        let source = NSAttributedString(
            string: "\(word) \(word)", attributes: Self.attributes(font))
        let baseline = LineCounter()
        let expected = prepareAttributed(
            source,
            measurer: AttributedSegmentMeasurer(
                source: source, memo: .init(byteLimit: 0), makeLine: baseline.makeLine)
        )
        let widths = try #require(expected.core.breakableWidths[0])
        #expect(widths.count == word.count)
        #expect(baseline.builds == [word: 2, "a": 60, "b": 60, " ": 2, "-": 1])
        let counter = LineCounter()
        let measurer = AttributedSegmentMeasurer(
            source: source, memo: .init(byteLimit: 1 << 20), makeLine: counter.makeLine)
        expectSame(prepareAttributed(source, measurer: measurer), expected)
        #expect(counter.builds == [word: 1, "a": 1, "b": 1, " ": 1, "-": 1])
    }

    @Test("Eight simultaneous prepares have distinct tables and match one uncached thread")
    func concurrentPrepares() {
        let count = 8
        let barrier = DispatchGroup()
        let finished = DispatchGroup()
        typealias Output = (
            table: ObjectIdentifier, entered: Bool, reused: Bool, text: PreparedAttributedText
        )
        let results = OSAllocatedUnfairLock(initialState: [Output]())
        let source = Self.mixedDocument()
        let uncached = AttributedSegmentMeasurer(source: source, memo: .init(byteLimit: 0))
        let expected = prepareAttributed(
            source, attachmentMetrics: Self.attachment, measurer: uncached)
        for _ in 0..<count {
            barrier.enter()
            finished.enter()
        }
        for _ in 0..<count {
            Thread.detachNewThread {
                let table = AttributedMeasurementMemo.current
                let document = Self.mixedDocument()
                var reachedAttachment = false
                let actual = prepareAttributed(document) { location in
                    if !reachedAttachment {
                        reachedAttachment = true
                        barrier.leave()
                        barrier.wait()
                    }
                    return Self.attachment(at: location)
                }
                if !reachedAttachment { barrier.leave() }
                let counter = LineCounter()
                let measurer = AttributedSegmentMeasurer(
                    source: document, makeLine: counter.makeLine)
                _ = prepareAttributed(
                    document, attachmentMetrics: Self.attachment, measurer: measurer)
                let output: Output = (
                    ObjectIdentifier(table), reachedAttachment,
                    counter.builds == ["mixed": 1, "kerning": 1], actual
                )
                results.withLock { $0.append(output) }
                finished.leave()
            }
        }
        finished.wait()
        let outputs = results.withLock { $0 }
        #expect(outputs.count == count)
        #expect(Set(outputs.map(\.table)).count == count)
        for output in outputs {
            #expect(output.entered)
            #expect(output.reused)
            expectSame(output.text, expected)
        }
    }

    @Test("Reaching the byte limit empties the whole table and oversized text stays uncached")
    func byteLimit() {
        let source = NSAttributedString(string: "x")
        let baseline = AttributedSegmentMeasurer(source: source, memo: .init(byteLimit: 0))
        let counter = LineCounter()
        let memo = AttributedMeasurementMemo(byteLimit: 3 * (128 + 3))
        let cached = AttributedSegmentMeasurer(
            source: source, memo: memo, makeLine: counter.makeLine)
        let oversize = String(repeating: "漢", count: 100)
        let texts = [
            "one", "two", "one", "two", "six", "six", "two", "one", oversize, oversize, "one",
        ]
        let counts = [1, 2, 2, 2, 3, 3, 4, 5, 6, 7, 8]
        for (text, expectedCount) in zip(texts, counts) {
            #expect(
                bits(cached.measure(text, fontAt: 0)) == bits(baseline.measure(text, fontAt: 0)))
            #expect(counter.builds.values.reduce(0, +) == expectedCount)
        }
    }
}
