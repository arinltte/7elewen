//
//  PanelHeader.swift
//  7elewen
//
//  Shared header for the floating panel's pages. Fixed-width leading/trailing
//  slots keep the back button and centered title perfectly aligned when
//  switching between Settings and About.
//

import SwiftUI

struct PanelHeader: View {
    let title: String
    let leadingAction: () -> Void
    var trailingIcon: String? = nil
    var trailingAction: (() -> Void)? = nil
    var trailingLabel: String = ""

    var body: some View {
        HStack(spacing: 0) {
            headerButton("chevron.left", label: "Back", action: leadingAction)

            Spacer(minLength: 0)

            Text(title)
                .font(.system(size: 15, weight: .semibold))

            Spacer(minLength: 0)

            if let trailingIcon, let trailingAction {
                headerButton(trailingIcon, label: trailingLabel, action: trailingAction)
            } else {
                // Match the leading button's fixed slot so the title stays centered.
                Color.clear.frame(width: 28, height: 28)
            }
        }
    }

    private func headerButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}