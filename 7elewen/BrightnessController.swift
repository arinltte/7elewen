//
//  BrightnessController.swift
//  7elewen
//
//  Created by Chen Jin Shen on 08/09/2026.
//

import CoreGraphics
import Darwin

/// Reads and sets the built-in display's brightness. On current macOS the private
/// brightness API lives in `DisplayServices.framework` (the standalone
/// CoreDisplay framework no longer ships), loaded lazily with `dlopen`.
@MainActor
final class BrightnessController {
    private let displayID: CGDirectDisplayID
    private let getFn: ((CGDirectDisplayID) -> Float?)?
    private let setFn: ((CGDirectDisplayID, Float) -> Void)?

    init() {
        displayID = Self.builtInDisplayID()
        (getFn, setFn) = Self.resolveFunctions()
    }

    /// Whether the brightness API resolved (always true on a real MacBook).
    var isAvailable: Bool { getFn != nil && setFn != nil }

    /// Current brightness in 0…1, or nil if the API isn't available.
    func current() -> Float? {
        getFn?(displayID)
    }

    /// Sets brightness in 0…1 (clamped), where 0 is the lowest setting.
    func set(_ value: Float) {
        setFn?(displayID, min(max(value, 0), 1))
    }

    private static func builtInDisplayID() -> CGDirectDisplayID {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
    }

    private static func resolveFunctions()
        -> (get: ((CGDirectDisplayID) -> Float?)?, set: ((CGDirectDisplayID, Float) -> Void)?)
    {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_NOW
        ), let getSym = dlsym(handle, "DisplayServicesGetBrightness"),
           let setSym = dlsym(handle, "DisplayServicesSetBrightness") else {
            return (nil, nil)
        }

        let get = unsafeBitCast(
            getSym,
            to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self
        )
        let set = unsafeBitCast(
            setSym,
            to: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self
        )

        return (
            { (display: CGDirectDisplayID) -> Float? in
                var value: Float = 0
                return get(display, &value) == 0 ? value : nil
            },
            { _ = set($0, $1) }
        )
    }
}