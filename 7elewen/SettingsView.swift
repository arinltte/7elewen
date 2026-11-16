//
//  SettingsView.swift
//  7elewen
//
//  Settings pane: a single lid-angle threshold (the display dims below it and
//  brightens back above it), the dim target brightness, and optional Low Power
//  Mode while the lid is shut. An "About" icon in the top-right opens the About
//  pane, which also holds the menu-bar icon and activation-glow personalization.
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

                    slider(
                        "Dim below",
                        value: $model.dimThreshold,
                        range: 1...100,
                        suffix: "°",
                        caption: "The screen dims as the lid closes past this angle, and turns back on once it opens past it."
                    )
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
            }
        }
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String,
        caption: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: caption == nil ? 6 : 4) {
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
            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}