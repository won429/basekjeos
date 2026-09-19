import Foundation

@main struct PlaybackQueueChecks {
    static func main() throws {
        func token(_ role: String, _ text: String) -> QueueAccessibilityToken { .init(role: role, text: text) }
        let rows = [token("AXButton", "추천 곡 재생"), token("AXRadioButton", "다음 트랙"),
                    token("AXButton", "이전 곡 재생"), token("AXStaticText", "이전 곡 가수"),
                    token("AXButton", "현재 곡 일시중지"), token("AXStaticText", "현재 곡"),
                    token("AXButton", "다음 곡 재생"), token("AXStaticText", "다음 곡"),
                    token("AXStaticText", "다음 가수"), token("AXButton", "작업 메뉴"), token("AXStaticText", "3:24"),
                    token("AXButton", "마지막 곡 재생"), token("AXStaticText", "마지막 곡 다른 가수"),
                    token("AXToolbar", "플레이어 바"), token("AXButton", "홈 추천 재생")]
        let result = try PlaybackQueueClient.parse(rows, currentTitle: "현재 곡")
        precondition(result.map(\.title) == ["다음 곡", "마지막 곡"])
        precondition(result.map(\.artist) == ["다음 가수", "다른 가수"])
        do { _ = try PlaybackQueueClient.parse(rows, currentTitle: "다른 재생 세션"); preconditionFailure() }
        catch PlaybackQueueError.unavailable {}
        let english = try PlaybackQueueClient.parse([token("AXRadioButton", "Up next"), token("AXButton", "Pause Now"),
                                                     token("AXButton", "Play Next"), token("AXStaticText", "Singer")], currentTitle: "Now")
        precondition(english.first?.title == "Next" && english.first?.artist == "Singer")
        let imageURL = URL(string: "https://lh3.googleusercontent.com/queue-cover")!
        let illustrated = try PlaybackQueueClient.parse([
            token("AXRadioButton", "Up next"), token("AXButton", "Pause Now"),
            token("AXButton", "Play Next"), .init(role: "AXImage", text: "", url: imageURL),
            token("AXStaticText", "Singer"), token("AXButton", "Play Last")], currentTitle: "Now")
        precondition(illustrated[0].artworkURL == imageURL && illustrated[1].artworkURL == nil)
        let selected = PlaybackQueueClient.playButtonTokenIndex(in: rows, currentTitle: "현재 곡", item: result[1])
        precondition(selected == 11)
        precondition(PlaybackQueueClient.playButtonTokenIndex(
            in: rows,
            currentTitle: "현재 곡",
            item: .init(id: 1, title: "다른 곡", artist: "")
        ) == nil)
        precondition(QueueArtworkLookup.matches(title: "TEARS", artist: "JISOO", candidateTitle: "Tears", candidateArtist: "JISOO"))
        precondition(!QueueArtworkLookup.matches(title: "TEARS", artist: "JISOO", candidateTitle: "Tears", candidateArtist: "Other"))
        let video: [String: Any] = ["videoRenderer": ["videoId": "Ss9haaorZ5s", "title": ["runs": [["text": "HWASA - HWASA Official Audio"]]], "ownerText": ["runs": [["text": "HWASA"]]]]]
        precondition(QueueArtworkLookup.youtubeArtwork(in: video, item: .init(id: 0, title: "HWASA", artist: "화사 (HWASA)")) != nil)
        precondition(QueueArtworkLookup.youtubeArtwork(in: video, item: .init(id: 0, title: "Different Song", artist: "HWASA")) == nil)
        print("PASS: actual queue order, current-track anchor, selectable rows, recommendation exclusion, Korean/English rows")
    }
}
