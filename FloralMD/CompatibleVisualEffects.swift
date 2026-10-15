import SwiftUI

extension View {
    /// Keep newer system styling without requiring it to open a workspace.
    @ViewBuilder
    func compatibleGlassEffect<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder
    func compatibleScrollEdgeEffectHidden() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectHidden()
        } else {
            self
        }
    }
}
