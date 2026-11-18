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
        let font: AnyObject?
        let kernBits: UInt64?

        init?(font: AnyObject?, kern: AnyObject?) {
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

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.font === rhs.font && lhs.kernBits == rhs.kernBits
        }
    }

    private struct Key: Hashable {
        let text: String
        let style: Style

        static func == (lhs: Self, rhs: Self) -> Bool {
            // CoreText receives the original code units, including decomposed spellings.
            guard lhs.style == rhs.style, lhs.text.utf8.count == rhs.text.utf8.count else {
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
            hasher.combine(style.font.map(ObjectIdentifier.init))
            hasher.combine(style.kernBits)
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

    private let byteLimit: Int
    private var entries: [Key: Metrics] = [:]
    private var estimatedBytes = 0

    var isEnabled: Bool { byteLimit > 0 }

    init(byteLimit: Int) {
        self.byteLimit = byteLimit
    }

    func measure(_ text: String, style: Style?, onMiss: () -> Metrics) -> Metrics {
        guard isEnabled, let style else { return onMiss() }
        var spelling = text
        spelling.makeContiguousUTF8()
        let key = Key(text: spelling, style: style)
        if let cached = entries[key] { return cached }

        let result = onMiss()
        // The fixed charge covers the key, metrics, text storage header, and dictionary bucket.
        let cost = 128 + spelling.utf8.count
        if cost >= byteLimit - estimatedBytes {
            entries.removeAll()
            estimatedBytes = 0
        }
        if cost < byteLimit {
            entries[key] = result
            estimatedBytes += cost
        }
        return result
    }
}
