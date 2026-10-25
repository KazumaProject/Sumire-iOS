import Foundation

public enum DeletionBoundary {
    public static let settingsKey = "editing.deleteBoundarySymbols"
    // Sumire dev 9506a0b: DeleteKeyFlickDeleteTargetRepository.DEFAULT_TARGET_SYMBOLS.
    public static let defaultSymbols = "。、！？「」『』ー."
    /// A bounded context, counted in whole graphemes for UIKit deleteBackward.
    /// A boundary immediately before the cursor is removed alone; otherwise stop before it.
    public static func backwardCount(context: String, symbols: String) -> Int {
        let boundaries = Set(symbols + " \u{3000}\n")
        var recent: [Character] = [], units = 0
        for character in context.reversed() {
            let size = character.utf16.count
            guard units + size <= 100 else { break }
            recent.append(character); units += size
        }
        guard let last = recent.first else { return 0 }
        if boundaries.contains(last) { return 1 }
        return recent.prefix { !boundaries.contains($0) && !$0.isWhitespace }.count
    }

    /// The forward counterpart used by Android's DeleteAfterCursorUntilSymbol.
    /// Limit the context to the same 100 UTF-16 units as InputConnection reads,
    /// but count and remove complete Swift Characters so a boundary never splits
    /// a composed grapheme.
    public static func forwardCount(context: String, symbols: String) -> Int {
        let boundaries = Set(symbols + " \u{3000}\n")
        var recent: [Character] = [], units = 0
        for character in context {
            let size = character.utf16.count
            guard units + size <= 100 else { break }
            recent.append(character); units += size
        }
        guard let first = recent.first else { return 0 }
        if boundaries.contains(first) { return 1 }
        return recent.prefix { !boundaries.contains($0) && !$0.isWhitespace }.count
    }
}
