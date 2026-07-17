import SwiftUI

/// Cycles the MyGhost icon through color variants (hue rotations), mirroring
/// the upstream About window's icon rotation. Hovering pauses the cycle;
/// clicking advances to the next color.
struct CyclingIconView: View {
    @EnvironmentObject var viewModel: AboutViewModel

    var body: some View {
        Image("MyGhostIcon")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .hueRotation(.degrees(viewModel.hueSteps[viewModel.hueIndex]))
            .animation(.easeInOut(duration: 0.8), value: viewModel.hueIndex)
            .frame(height: 128)
            .onHover { hovering in
                viewModel.isHovering = hovering
            }
            .onTapGesture {
                viewModel.advanceToNextIcon()
            }
            .accessibilityLabel("MyGhost Application Icon")
            .accessibilityHint("Click to cycle through icon colors")
    }
}
