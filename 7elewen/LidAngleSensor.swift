//
//  LidAngleSensor.swift
//  7elewen
//
//  Created by Chen Jin Shen on 08/09/2026.
//

import Foundation
import IOKit
import IOKit.hid
import os
import SwiftUI

/// Reads the MacBook lid angle from the internal Apple HID device and exposes it
/// as observable state. `angle` is roughly degrees: ~0 fully closed, ~120 open.
///
/// Device discovery is heuristic because Apple's lid-sensor HID device varies by
/// model: first we match by product name / usage page, then fall back to probing
/// the angle feature report.
@MainActor
@Observable
final class LidAngleSensor {
    private(set) var angle = 120.0

    /// Invoked on the main actor whenever a fresh angle is read.
    var onAngleChange: ((Double) -> Void)?


    // nonisolated(unsafe) so deinit can reach these from its nonisolated context.
    @ObservationIgnored nonisolated(unsafe) private var hidDevice: IOHIDDevice?
    @ObservationIgnored nonisolated(unsafe) private var isDeviceOpen = false
    @ObservationIgnored nonisolated(unsafe) private var timer: Timer?

    @ObservationIgnored private var report = [UInt8](repeating: 0, count: 8)

    nonisolated private static let noOptions = IOOptionBits(kIOHIDOptionsTypeNone)
    nonisolated private static let logger = Logger(subsystem: "arinltte.7elewen", category: "LidSensor")

    init() {
        hidDevice = Self.findLidSensor()
    }

    deinit {
        timer?.invalidate()
        timer = nil
        if isDeviceOpen, let device = hidDevice {
            IOHIDDeviceClose(device, Self.noOptions)
        }
    }

    // MARK: Control

    func start() {
        guard timer == nil, let device = hidDevice else { return }
        guard IOHIDDeviceOpen(device, Self.noOptions) == kIOReturnSuccess else { return }
        isDeviceOpen = true
        // ~2.5 Hz: double the previous interval to cut polling cost further, at the
        // cost of a slightly slower open/close detection (~0.4 s).
        timer = .scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop, so the callback fires on the main thread.
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if isDeviceOpen, let device = hidDevice {
            IOHIDDeviceClose(device, Self.noOptions)
            isDeviceOpen = false
        }
    }

    // MARK: Polling

    private func poll() {
        guard let device = hidDevice else { return }
        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length)
        guard result == kIOReturnSuccess, length >= 3 else { return }
        let raw = Double(UInt16(report[2]) << 8 | UInt16(report[1]))
        if abs(raw - angle) > 0.5 {
            Self.logger.info("lid angle \(raw, format: .fixed(precision: 1))")
        }
        angle = raw
        onAngleChange?(raw)
    }
}

// MARK: - Hardware discovery

extension LidAngleSensor {
    /// Finds the lid-angle HID device, matching by name/usage first, then
    /// falling back to probing the angle feature report on non-input devices.
    nonisolated static func findLidSensor() -> IOHIDDevice? {
        let devices = AppleHID.enumerate()
        if let preferred = devices.first(where: { AppleHID.isLikelyLidSensor($0) }) {
            return preferred
        }
        return devices.first(where: { !AppleHID.isInputSurface($0) && AppleHID.probeAngle($0) != nil })
    }
}

private enum AppleHID {
    static func enumerate() -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x05AC] as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        let deviceSet = IOHIDManagerCopyDevices(manager) as NSSet?
        let devices = (deviceSet?.allObjects as? [IOHIDDevice]) ?? []
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        return devices
    }

    static func productName(_ device: IOHIDDevice) -> String {
        IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
    }

    static func isLikelyLidSensor(_ device: IOHIDDevice) -> Bool {
        let name = productName(device).lowercased()
        if name.contains("lid") || name.contains("angle") || name.contains("als") { return true }
        let usagePage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue ?? 0
        let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue ?? 0
        // The lid-angle sensor is the HID "Sensors" page (0x20) usage 0x8A. Several
        // other enumerable devices also live on 0x20 (usages 0x73, 0x7A), so page
        // alone is not specific enough.
        return usagePage == 0x20 && usage == 0x8A
    }

    static func isInputSurface(_ device: IOHIDDevice) -> Bool {
        let name = productName(device).lowercased()
        return name.contains("keyboard") || name.contains("trackpad") || name.contains("mouse")
    }

    static func probeAngle(_ device: IOHIDDevice) -> Double? {
        let options = IOOptionBits(kIOHIDOptionsTypeNone)
        guard IOHIDDeviceOpen(device, options) == kIOReturnSuccess else { return nil }
        defer { IOHIDDeviceClose(device, options) }
        var report = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length)
        guard result == kIOReturnSuccess, length >= 3 else { return nil }
        let angle = Double(UInt16(report[2]) << 8 | UInt16(report[1]))
        // A lid angle is 0…~180°; reject implausible values from other devices.
        guard (0...180).contains(angle) else { return nil }
        return angle
    }
}
