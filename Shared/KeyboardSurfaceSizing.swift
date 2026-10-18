import Foundation

/// Fits the candidate viewport into the keyboard's height budget before taking
/// any space from the key grid. The requested row count remains independent of
/// the viewport so clipped rows stay reachable by vertical scrolling.
struct KeyboardSurfaceSizingPlan: Equatable {
    static let candidateRowHeight: CGFloat = 44
    let keyAreaHeight: CGFloat
    let candidateHeight: CGFloat
    let totalHeight: CGFloat

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
