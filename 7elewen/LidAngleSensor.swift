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
/// the angle feature report. The `diagnostic` report surfaces what happened.
@MainActor
@Observable
final class LidAngleSensor {
    private(set) var angle = 120.0
    private(set) var isAvailable = false
    private(set) var tick: UInt = 0

    /// Full diagnostic report from hardware detection.
    @ObservationIgnored private(set) var diagnostic: LASDiagnostic?

    /// Invoked on the main actor whenever a fresh angle is read.
    var onAngleChange: ((Double) -> Void)?

    var status: String {
        guard isAvailable else { return diagnostic?.statusMessage ?? "Sensor not available" }
        return switch angle {
        case ..<5: "Lid closed"
        case ..<45: "Lid slightly open"
        case ..<90: "Lid partially open"
        case ..<120: "Lid mostly open"
        default: "Lid fully open"
        }
    }

    // nonisolated(unsafe) so deinit can reach these from its nonisolated context.
    @ObservationIgnored nonisolated(unsafe) private var hidDevice: IOHIDDevice?
    @ObservationIgnored nonisolated(unsafe) private var isDeviceOpen = false
    @ObservationIgnored nonisolated(unsafe) private var timer: Timer?

    @ObservationIgnored private var report = [UInt8](repeating: 0, count: 8)

    nonisolated private static let noOptions = IOOptionBits(kIOHIDOptionsTypeNone)
    nonisolated private static let logger = Logger(subsystem: "arinltte.7elewen", category: "LidSensor")

    init() {
        let diag = LASDiagnostic.run()
        diagnostic = diag
        switch diag.probeResult {
        case .foundStandard(let device), .probedCandidate(let device, _):
            hidDevice = device
            isAvailable = true
        case .notFound:
            hidDevice = nil
            isAvailable = false
        }
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
        guard isAvailable, timer == nil, let device = hidDevice else { return }
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
        tick &+= 1
        onAngleChange?(raw)
    }
}

// MARK: - Hardware discovery

struct LASDiagnostic {
    enum ProbeResult {
        /// Found a device whose name/usage unambiguously identifies it as the lid sensor.
        case foundStandard(IOHIDDevice)
        /// No name match — fell back to reading the angle report to identify the device.
        case probedCandidate(IOHIDDevice, String)
        case notFound
    }

    let probeResult: ProbeResult
    let candidateNames: [String]

    var statusMessage: String {
        switch probeResult {
        case .foundStandard:
            return "Lid angle sensor found"
        case .probedCandidate(_, let name):
            return "Lid sensor detected (\(name))"
        case .notFound:
            if candidateNames.isEmpty {
                return "No Apple HID devices found — lid sensing unavailable"
            }
            return "Lid sensor not found among: \(candidateNames.joined(separator: ", "))"
        }
    }

    static func run() -> LASDiagnostic {
        let devices = AppleHID.enumerate()
        let names = devices.map { AppleHID.productName($0) }

        if let preferred = devices.first(where: { AppleHID.isLikelyLidSensor($0) }) {
            return LASDiagnostic(probeResult: .foundStandard(preferred), candidateNames: names)
        }

        // Fall back: probe for the angle feature report on non-input devices.
        for device in devices {
            let name = AppleHID.productName(device)
            if !AppleHID.isInputSurface(device), AppleHID.probeAngle(device) != nil {
                return LASDiagnostic(probeResult: .probedCandidate(device, name), candidateNames: names)
            }
        }

        return LASDiagnostic(probeResult: .notFound, candidateNames: names)
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
