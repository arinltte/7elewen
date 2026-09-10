//
//  Glass.swift
//  7elewen
//
//  Liquid Glass surface primitives (native material — no fake gradient fills).
//

import AppKit
import SwiftUI

/// A native translucent material backed by NSVisualEffectView — the platform's
/// liquid glass: it samples and blurs whatever is behind the window, adapts to
/// light/dark automatically, and manages its own contrast/tint.
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
    }
}

/// The app surface: pure native popover glass with a continuous corner. No
/// synthetic gradients — the material itself is the glassmorphism effect.
struct GlassSurface: View {
    var cornerRadius: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.clear)
            .background(
                VisualEffectView(material: .popover, blendingMode: .behindWindow)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}