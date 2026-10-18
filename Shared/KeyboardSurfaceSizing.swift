import Foundation

/// Fits the candidate viewport into the keyboard's height budget before taking
/// any space from the key grid. The requested row count remains independent of
/// the viewport so clipped rows stay reachable by vertical scrolling.
struct KeyboardSurfaceSizingPlan: Equatable {
    static let candidateRowHeight: CGFloat = 44
    let keyAreaHeight: CGFloat
    let candidateHeight: CGFloat
    let totalHeight: CGFloat

    /// The keyboard host window may itself be sized to the keyboard. Use the
    /// display height as the cap so the available budget does not shrink with
    /// the keyboard's current frame. Fall back to the window only when screen
    /// metrics are unavailable (such as isolated layout tests).
    static func availableHeight(screenHeight: CGFloat?, windowHeight: CGFloat?) -> CGFloat {
        if let screenHeight, screenHeight.isFinite, screenHeight > 0 { return screenHeight }
        if let windowHeight, windowHeight.isFinite, windowHeight > 0 { return windowHeight }
        return 1000
    }

    static func make(keyAreaHeight: CGFloat, candidateHeight: CGFloat,
                     bottomInset: CGFloat, availableHeight: CGFloat) -> Self {
        let maximumHeight = max(210, availableHeight * 0.72)
        let minimumCandidateHeight = candidateRowHeight
        // If the preferred keyboard is too tall for the host, constrain its
        // base size once, independently of how many candidate rows are saved.
        let maximumKeyAreaHeight = max(minimumCandidateHeight,
            maximumHeight - bottomInset - minimumCandidateHeight)
        let fittedKeyArea = min(keyAreaHeight, maximumKeyAreaHeight)
        let candidateRoom = max(minimumCandidateHeight,
            maximumHeight - bottomInset - fittedKeyArea)
        let fittedCandidates = min(candidateHeight,
            floor(candidateRoom / candidateRowHeight) * candidateRowHeight)
        let visibleCandidates = max(minimumCandidateHeight, fittedCandidates)
        return Self(keyAreaHeight: fittedKeyArea,
                    candidateHeight: visibleCandidates,
                    totalHeight: fittedKeyArea + visibleCandidates + bottomInset)
    }
}
