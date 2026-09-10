//
//  SettingsView.swift
//  7elewen
//
//  Settings pane: lid-angle thresholds for auto dim/brighten, the dim target
//  brightness, and optional Low Power Mode while the lid is shut. An "About"
//  icon in the top-right opens the About pane. The dim and brighten thresholds
//  are kept at least one degree apart so they can never coincide.
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    let onBack: () -> Void
    @State private var showingAbout = false

    var body: some View {
        @Bindable var model = model

        Group {
            if showingAbout {
                AboutView(onBack: { showingAbout = false })
            } else {
                VStack(spacing: 16) {
                    PanelHeader(
                        title: "Settings",
                        leadingAction: onBack,
                        trailingIcon: "info.circle",
                        trailingAction: { showingAbout = true },
                        trailingLabel: "About"
                    )

                    slider("Dim when lid closes", value: $model.dimAngle, range: 0...30, suffix: "°")
                    slider("Brighten when lid opens", value: $model.brightenAngle, range: 1...30, suffix: "°")
                    slider("Dim brightness to", value: $model.dimBrightness, range: 0...50, suffix: "%")

                    Divider()

                    Toggle(isOn: $model.lowPowerModeWhenClosed) {
                        HStack(spacing: 8) {
                            Image(systemName: "leaf")
                                .foregroundStyle(.green)
                            Text("Low Power Mode when lid is closed")
                                .font(.system(size: 13))
                        }
                    }
                    .toggleStyle(.switch)

                    Spacer(minLength: 0)
                }
                .onChange(of: model.dimAngle) { _, newValue in
                    if model.brightenAngle <= newValue + 1 {
                        model.brightenAngle = min(newValue + 1, 30)
                    }
                }
                .onChange(of: model.brightenAngle) { _, newValue in
                    if model.dimAngle >= newValue - 1 {
                        model.dimAngle = max(newValue - 1, 0)
                    }
                }
            }
        }
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12.5))
                Spacer()
                Text("\(Int(value.wrappedValue))\(suffix)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: 1)
                .controlSize(.small)
        }
    }
}