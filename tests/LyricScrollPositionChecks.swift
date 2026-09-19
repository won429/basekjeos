import Foundation

@main struct LyricScrollPositionChecks {
    static func main() {
        precondition(
            LyricScrollLayout.targetOffset(
                lineMidY: 100,
                documentHeight: 2_000,
                viewportHeight: 600
            ) == 0,
            "The first lyric stays at the beginning of the scroll view"
        )
        precondition(
            LyricScrollLayout.targetOffset(
                lineMidY: 500,
                documentHeight: 2_000,
                viewportHeight: 600
            ) == 200,
            "The active timestamp aligns to the vertical center"
        )
        precondition(
            LyricScrollLayout.targetOffset(
                lineMidY: 1_900,
                documentHeight: 2_000,
                viewportHeight: 600
            ) == 1_400,
            "The final lyric does not scroll beyond the document"
        )
        precondition(
            LyricScrollLayout.targetOffset(
                lineMidY: 100,
                documentHeight: 400,
                viewportHeight: 600
            ) == 0,
            "Short lyric documents remain at their origin"
        )
        print("PASS: timestamped lyrics align at the center and clamp to document bounds")
    }
}
