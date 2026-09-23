//
//  ContentView.swift
//  7elewen
//
//  The floating Liquid Glass surface, presented from the menu-bar infinity item:
//    · activate / deactivate control in the center
//    · status text just below the control
//    · settings gear top-right, "Exit" bottom-right
//  When active, a selectable glow effect (pulse / circulating / off, chosen in
//  the About pane) animates around the control — and only while the panel is
//  actually presented (removed otherwise, so nothing keeps animating in the
//  background).
//

import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(MenuBarPresenter.self) private var presenter
    @State private var showingSettings = false

    private var accent: Color { .orange }

    var body: some View {
        ZStack {
            GlassSurface(cornerRadius: 30)

            Group {
                if showingSettings {
                    settingsContent
                        .transition(.opacity)
                } else {
                    mainContent
                        .transition(.opacity)
                }
            }
            .padding(22)
        }
        .frame(width: 360, height: 360)
        .scaleEffect(presenter.isPresented ? 1.0 : 0.96, anchor: .top)
        .opacity(presenter.isPresented ? 1.0 : 0.0)
        .animation(
            presenter.reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.85),
            value: showingSettings
        )
    }

    // MARK: Main content

    private var mainContent: some View {
        VStack(spacing: 0) {
            header
            Spacer()
            actionControl
            statusText
                .padding(.top, 16)
            Spacer()
            footer
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            Button {
                withAnimation { showingSettings = true }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .contentShape(Circle())
            }
            .buttonStyle(SymbolButtonStyle())
            .accessibilityLabel("Settings")
        }
    }

    private var actionControl: some View {
        Button(action: { model.toggle() }) {
            VStack(spacing: 14) {
                ZStack {
                    if model.isEnabled && presenter.isPresented {
                        switch model.buttonEffect {
                        case "pulse":
                            activationGlow
                            activationRing
                        case "circulate":
                            circulatingGlow
                        default:
                            EmptyView()
                        }
                    }

                    Circle()
                        .fill(
                            model.isEnabled
                                ? AnyShapeStyle(accent)
                                : AnyShapeStyle(.quaternary.opacity(0.55))
                        )
                        .frame(width: 96, height: 96)
                        .shadow(
                            color: .black.opacity(model.isEnabled ? 0.25 : 0.12),
                            radius: 10,
                            y: 4
                        )

                    Image(systemName: model.isEnabled ? "infinity" : "moon.zzz.fill")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(model.isEnabled ? .white : .secondary)
                }
                Text(model.isEnabled ? "Deactivate" : "Activate")
                    .font(.system(size: 16, weight: .semibold))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(model.isBusy)
        .accessibilityLabel(model.isEnabled ? "Deactivate" : "Activate")
    }

    /// Pulsing orange glow. Rendered only while activated *and* the panel is on
    /// screen — `presenter.isPresented` removes it the moment the panel is
    /// dismissed, so `TimelineView` stops producing frames (no background work).
    /// Selected via the About pane's "Activation Glow" → Pulse option.
    private var activationGlow: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = t.truncatingRemainder(dividingBy: 1.8) / 1.8     // 0…1
            let pulse = phase < 0.5 ? phase * 2 : (1 - phase) * 2        // 0…1…0
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .orange.opacity(0.42 + 0.33 * pulse),
                            .orange.opacity(0),
                        ],
                        center: .center,
                        startRadius: 40,
                        endRadius: 78 + 18 * pulse
                    )
                )
                .frame(width: 180, height: 180)
        }
        .allowsHitTesting(false)
    }

    /// Orbiting orange gradient ring.
    private var activationRing: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let angle = timeline.date.timeIntervalSinceReferenceDate * 45
            Circle()
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [.orange, .yellow, .orange]),
                        center: .center,
                        angle: .degrees(angle)
                    ),
                    lineWidth: 3
                )
                .frame(width: 110, height: 110)
                .shadow(color: .orange.opacity(0.6), radius: 12)
        }
        .allowsHitTesting(false)
    }

    /// Circulating glow: a comet-like orange arc with a fading tail that
    /// travels around the button (plus a faint track so the motion reads).
    /// Rendered only while activated *and* the panel is on screen, same as the
    /// pulse effect. Selected via the About pane's "Activation Glow" →
    /// Circulate option.
    private var circulatingGlow: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let angle = timeline.date.timeIntervalSinceReferenceDate * 115
            ZStack {
                Circle()
                    .stroke(.orange.opacity(0.12), lineWidth: 2)
                    .frame(width: 110, height: 110)

                Circle()
                    .trim(from: 0.0, to: 0.25)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [.orange.opacity(0), .orange]),
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(90)
                        ),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .frame(width: 110, height: 110)
                    .rotationEffect(.degrees(angle))
                    .shadow(color: .orange.opacity(0.85), radius: 10)
            }
        }
        .allowsHitTesting(false)
    }

    private var statusText: some View {
        Text(model.isBusy ? "Working…" : model.detailText)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Exit") {
                NSApp.terminate(nil)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
        }
    }

    // MARK: Settings content

    private var settingsContent: some View {
        SettingsView(onBack: {
            withAnimation { showingSettings = false }
        })
    }
}

// MARK: - Button styles

/// Subtle, immediate press feedback with a quick spring-back.
private struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct SymbolButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1.0)
    }
}