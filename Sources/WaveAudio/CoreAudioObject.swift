import Foundation
import CoreAudio
import AudioToolbox
import WaveCore

/// A Core Audio error carried as a Swift error, with the four-character code
/// spelled out. `1852797029` means nothing; `'nope'` is searchable.
public struct CoreAudioError: Error, CustomStringConvertible, Equatable {
    public let status: OSStatus
    public let operation: String

    public init(_ status: OSStatus, _ operation: String) {
        self.status = status
        self.operation = operation
    }

    public var fourCharCode: String {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "" }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    public var description: String {
        let code = fourCharCode
        let suffix = code.isEmpty ? "" : " ('\(code)')"
        return "\(operation) failed with status \(status)\(suffix)"
    }

    public var localizedDescription: String { description }

    /// The handful of statuses worth explaining in the UI rather than dumping.
    public var friendlyExplanation: String? {
        switch status {
        case kAudioHardwareBadObjectError:
            return "The audio object went away before Wave could use it."
        case kAudioHardwareBadDeviceError:
            return "That output device is no longer available."
        case kAudioHardwareNotRunningError:
            return "Core Audio is not running."
        case kAudioHardwareUnsupportedOperationError:
            return "macOS refused this operation on this device."
        case kAudioHardwareIllegalOperationError:
            return "macOS refused the request. This usually means system audio recording permission is missing."
        case kAudioHardwareUnknownPropertyError:
            return "The device does not expose the property Wave needs."
        default:
            return nil
        }
    }
}

@discardableResult
func checked(_ operation: String, _ body: () -> OSStatus) throws -> OSStatus {
    let status = body()
    guard status == noErr else { throw CoreAudioError(status, operation) }
    return status
}

/// Typed property access on top of `AudioObjectGetPropertyData`.
///
/// The raw API needs a size query, a correctly sized allocation and a second
/// call for every read; getting any of that subtly wrong yields garbage rather
/// than an error. Funnelling every read in Wave through these few generics
/// means that reasoning happens once.
public extension AudioObjectID {

    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != AudioObjectID.unknown }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    func hasProperty(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var address = Self.address(selector, scope: scope, element: element)
        return AudioObjectHasProperty(self, &address)
    }

    func propertySize(_ address: AudioObjectPropertyAddress,
                      qualifierSize: UInt32 = 0,
                      qualifier: UnsafeRawPointer? = nil) throws -> UInt32 {
        var address = address
        var size: UInt32 = 0
        try checked("AudioObjectGetPropertyDataSize(\(address.mSelector.fourCharString))") {
            AudioObjectGetPropertyDataSize(self, &address, qualifierSize, qualifier, &size)
        }
        return size
    }

    /// Reads a fixed-size value.
    func read<T>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                 defaultValue: T) throws -> T {
        var address = Self.address(selector, scope: scope, element: element)
        var size = UInt32(MemoryLayout<T>.size)
        var value = defaultValue
        try checked("AudioObjectGetPropertyData(\(selector.fourCharString))") {
            withUnsafeMutablePointer(to: &value) { pointer in
                AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
            }
        }
        return value
    }

    /// Reads a fixed-size value that requires a qualifier, such as
    /// `kAudioHardwarePropertyTranslatePIDToProcessObject`.
    func read<T, Q>(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                    defaultValue: T,
                    qualifier: Q) throws -> T {
        var address = Self.address(selector, scope: scope, element: element)
        var qualifierValue = qualifier
        var value = defaultValue
        var size = UInt32(MemoryLayout<T>.size)
        try checked("AudioObjectGetPropertyData(\(selector.fourCharString))") {
            withUnsafeMutablePointer(to: &qualifierValue) { qualifierPointer in
                withUnsafeMutablePointer(to: &value) { valuePointer in
                    AudioObjectGetPropertyData(self,
                                               &address,
                                               UInt32(MemoryLayout<Q>.size),
                                               qualifierPointer,
                                               &size,
                                               valuePointer)
                }
            }
        }
        return value
    }

    /// Reads a variable-length array property.
    ///
    /// `filler` seeds the buffer before the read so the array is fully
    /// initialised even if Core Audio returns fewer elements than the size
    /// query promised, which it does when a device disappears between the two
    /// calls.
    func readArray<T>(_ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                      filler: T) throws -> [T] {
        var address = Self.address(selector, scope: scope, element: element)
        var size = try propertySize(address)
        let capacity = Int(size) / MemoryLayout<T>.stride
        guard capacity > 0 else { return [] }

        var values = [T](repeating: filler, count: capacity)
        try checked("AudioObjectGetPropertyData(\(selector.fourCharString))") {
            values.withUnsafeMutableBytes { raw in
                AudioObjectGetPropertyData(self, &address, 0, nil, &size, raw.baseAddress)
            }
        }
        let returned = Int(size) / MemoryLayout<T>.stride
        if returned < capacity { values.removeLast(capacity - returned) }
        return values
    }

    func readString(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> String {
        let cfString: CFString = try read(selector, scope: scope, element: element, defaultValue: "" as CFString)
        return cfString as String
    }

    func readBool(_ selector: AudioObjectPropertySelector,
                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                  element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> Bool {
        let value: UInt32 = try read(selector, scope: scope, element: element, defaultValue: 0)
        return value != 0
    }

    func write<T>(_ selector: AudioObjectPropertySelector,
                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                  element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                  value: T) throws {
        var address = Self.address(selector, scope: scope, element: element)
        var value = value
        try checked("AudioObjectSetPropertyData(\(selector.fourCharString))") {
            AudioObjectSetPropertyData(self, &address, 0, nil,
                                       UInt32(MemoryLayout<T>.size), &value)
        }
    }
}

/// A property listener that removes itself when released.
///
/// Core Audio listeners are registered against a raw block pointer, so
/// forgetting to remove one leaves a dangling callback that fires into freed
/// memory on the next hot-plug. Tying registration to an object's lifetime is
/// the only way this stays reliable across the number of listeners Wave keeps.
public final class AudioPropertyObserver {

    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var registered = false

    public init(objectID: AudioObjectID,
                selector: AudioObjectPropertySelector,
                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                queue: DispatchQueue,
                handler: @escaping () -> Void) throws {
        var address = AudioObjectID.address(selector, scope: scope, element: element)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }

        try checked("AudioObjectAddPropertyListenerBlock(\(selector.fourCharString))") {
            AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
        }

        self.objectID = objectID
        self.address = address
        self.queue = queue
        self.block = block
        self.registered = true
    }

    deinit {
        guard registered else { return }
        let status = AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
        if status != noErr {
            Diagnostics.shared.warning("CoreAudio",
                                       "Removing listener for \(address.mSelector.fourCharString) returned \(status)")
        }
    }
}

extension AudioObjectPropertySelector {
    /// Four-character rendering used throughout Wave's diagnostics.
    var fourCharString: String {
        let value = UInt32(self)
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return String(value) }
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }
}
