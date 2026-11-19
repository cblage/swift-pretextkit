import CoreText
import Darwin
import Foundation
import os

private let configuredByteLimit = OSAllocatedUnfairLock(initialState: 256 << 20)

/// The byte limit for each thread's attributed measurement cache. Set it once before preparing
/// attributed text. Each thread reads it when it creates its table. The default is 256 MiB.
public var attributedMeasurementCacheByteLimit: Int {
    get { configuredByteLimit.withLock { $0 } }
    set { configuredByteLimit.withLock { $0 = max(0, newValue) } }
}

final class AttributedMeasurementMemo {
    typealias Metrics = AttributedSegmentMeasurer.Metrics

    struct Style: Equatable {
        let font: UnsafeRawPointer?
        let kernBits: UInt64?

        init?(font: UnsafeRawPointer?, kern: AnyObject?) {
            self.font = font
            if let kern {
                // A Boolean also bridges to NSNumber, but it has a different CF type.
                guard kern.isKind?(of: NSNumber.self) == true,
                    CFGetTypeID(kern) == CFNumberGetTypeID()
                else { return nil }
                kernBits = unsafeDowncast(kern, to: NSNumber.self).doubleValue.bitPattern
            } else {
                kernBits = nil
            }
        }
    }

    private struct Key: Hashable {
        let text: String
        let style: Style
        let runBreaks: [Int]

        static func == (lhs: Self, rhs: Self) -> Bool {
            // CoreText receives the original code units, including decomposed spellings.
            guard lhs.style == rhs.style, lhs.runBreaks == rhs.runBreaks,
                lhs.text.utf8.count == rhs.text.utf8.count
            else {
                return false
            }
            var left = lhs.text
            var right = rhs.text
            return left.withUTF8 { leftBytes in
                right.withUTF8 { rightBytes in
                    guard let leftBase = leftBytes.baseAddress,
                        let rightBase = rightBytes.baseAddress
                    else { return leftBytes.isEmpty }
                    return memcmp(leftBase, rightBase, leftBytes.count) == 0
                }
            }
        }

        func hash(into hasher: inout Hasher) {
            var spelling = text
            spelling.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
            hasher.combine(style.font)
            hasher.combine(style.kernBits)
            if !runBreaks.isEmpty { hasher.combine(runBreaks) }
        }
    }

    private static let threadKey: pthread_key_t? = {
        var key = pthread_key_t()
        let result = pthread_key_create(&key) { pointer in
            Unmanaged<AttributedMeasurementMemo>.fromOpaque(pointer).release()
        }
        return result == 0 ? key : nil
    }()

    static var current: AttributedMeasurementMemo {
        guard let threadKey else { return AttributedMeasurementMemo(byteLimit: 0) }
        if let pointer = pthread_getspecific(threadKey) {
            return Unmanaged<AttributedMeasurementMemo>.fromOpaque(pointer).takeUnretainedValue()
        }
        let memo = AttributedMeasurementMemo(byteLimit: attributedMeasurementCacheByteLimit)
        let retained = Unmanaged.passRetained(memo)
        if pthread_setspecific(threadKey, retained.toOpaque()) != 0 { retained.release() }
        return memo
    }

    private final class Font {
        // One owner prevents address reuse. Only this thread builds lines with the copy.
        let source: AnyObject?
        let copy: AnyObject

        init(_ address: UnsafeRawPointer?) {
            source = address.map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
            copy = Self.copy(of: address)
        }

        static func copy(of address: UnsafeRawPointer?) -> AnyObject {
            guard let address else {
                // CoreText specifies Helvetica 12 when the run has no font attribute.
                return CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            }
            return Unmanaged<AnyObject>.fromOpaque(address)._withUnsafeGuaranteedRef { object in
                guard CFGetTypeID(object) == CTFontGetTypeID() else { return object }
                return Unmanaged<CTFont>.fromOpaque(address)._withUnsafeGuaranteedRef {
                    CTFontCreateCopyWithAttributes($0, 0, nil, nil)
                }
            }
        }
    }

    private let byteLimit: Int
    // The charge covers a CoreText copy, its source owner and their dictionary bucket.
    private static let fontCost = 1024
    private var entries: [Key: Metrics] = [:]
    private var fonts: [UnsafeRawPointer?: Font] = [:]
    private var estimatedBytes = 0
    private var generation = 0

    var isEnabled: Bool { byteLimit > 0 }

    init(byteLimit: Int) {
        self.byteLimit = byteLimit
    }

    func measurementFont(for address: UnsafeRawPointer?) -> AnyObject {
        if let font = fonts[address] { return font.copy }
        // A mixed run can introduce a font without a metric entry of its own.
        guard !entries.isEmpty, Self.fontCost < byteLimit - estimatedBytes else {
            return Font.copy(of: address)
        }
        let font = Font(address)
        fonts[address] = font
        estimatedBytes += Self.fontCost
        return font.copy
    }

    func measure(
        _ text: String, style: Style?, runBreaks: [Int] = [], onMiss: () -> Metrics
    ) -> Metrics {
        guard isEnabled, let style else { return onMiss() }
        var spelling = text
        spelling.makeContiguousUTF8()
        let key = Key(text: spelling, style: style, runBreaks: runBreaks)
        if let cached = entries[key] { return cached }

        // The fixed charge covers the key, metrics, text storage header, and dictionary bucket.
        let runCost = runBreaks.isEmpty ? 0 : 32 + runBreaks.capacity * MemoryLayout<Int>.stride
        let keyCost = 128 + spelling.utf8.count + runCost
        // A missing source font needs no address pin, even when only the metrics fit.
        let keepFont = style.font != nil || keyCost + Self.fontCost < byteLimit
        var needsFont = keepFont && fonts.index(forKey: style.font) == nil
        var cost = keyCost + (needsFont ? Self.fontCost : 0)
        if cost >= byteLimit - estimatedBytes {
            entries.removeAll()
            fonts.removeAll()
            estimatedBytes = 0
            generation &+= 1
            needsFont = keepFont
            cost = keyCost + (needsFont ? Self.fontCost : 0)
        }
        guard cost < byteLimit else { return onMiss() }
        if needsFont { fonts[style.font] = Font(style.font) }
        estimatedBytes += cost
        let reservedGeneration = generation
        let result = onMiss()
        // A nested miss can clear the reservation and its font while it builds the line.
        if generation == reservedGeneration { entries[key] = result }
        return result
    }
}
