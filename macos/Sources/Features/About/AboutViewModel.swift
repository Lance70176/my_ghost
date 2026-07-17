import Combine

class AboutViewModel: ObservableObject {
    /// Index into `hueSteps`. The About icon shows the MyGhost icon tinted by
    /// the current step, cycling like the upstream Ghostty icon variants did.
    @Published var hueIndex: Int = 0
    @Published var isHovering: Bool = false

    /// Hue rotations (degrees) applied to the MyGhost icon — five color
    /// variants including the original.
    let hueSteps: [Double] = [0, 72, 144, 216, 288]

    private var timerCancellable: AnyCancellable?

    func startCyclingIcons() {
        timerCancellable = Timer.publish(every: 3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, !isHovering else { return }
                advanceToNextIcon()
            }
    }

    func stopCyclingIcons() {
        timerCancellable = nil
        hueIndex = 0
    }

    func advanceToNextIcon() {
        hueIndex = (hueIndex + 1) % hueSteps.count
    }
}
