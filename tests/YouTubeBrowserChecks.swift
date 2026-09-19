import Foundation

@main struct YouTubeBrowserChecks {
    static func main() {
        precondition(YouTubeBrowserPlayback.playbackState(for: "Pause") == true)
        precondition(YouTubeBrowserPlayback.playbackState(for: "  일시 중지 ") == true)
        precondition(YouTubeBrowserPlayback.playbackState(for: "재생") == false)
        precondition(YouTubeBrowserPlayback.playbackState(for: "") == nil)
        precondition(YouTubeBrowserPlayback.playbackState(for: "Loading") == nil)
        for text in ["https://music.youtube.com", "https://music.youtube.com/watch?v=example"] {
            precondition(YouTubeBrowserPlayback.isMusicURL(URL(string: text)))
        }
        for text in ["https://youtube.com/watch?v=example", "https://music.youtube.com.evil.test", "https://example.com/music.youtube.com", "file:///music.youtube.com", "http://music.youtube.com"] {
            precondition(!YouTubeBrowserPlayback.isMusicURL(URL(string: text)))
        }
        precondition(!YouTubeBrowserPlayback.isMusicURL(nil))
        precondition(YouTubeBrowserPlayback.seekValue(seconds: 94, duration: 188, minimum: 0, maximum: 188) == 94)
        precondition(YouTubeBrowserPlayback.seekValue(seconds: 94, duration: 188, minimum: 0, maximum: 1) == 0.5)
        precondition(YouTubeBrowserPlayback.seekValue(seconds: 300, duration: 188, minimum: 0, maximum: 188) == 188)
        precondition(YouTubeBrowserPlayback.seekValue(seconds: 10, duration: 0, minimum: 0, maximum: 0) == nil)
        precondition(YouTubeBrowserCachePolicy.canReuseSnapshot(playing: true, age: 9.99, invalidated: false))
        precondition(!YouTubeBrowserCachePolicy.canReuseSnapshot(playing: true, age: 10, invalidated: false))
        precondition(YouTubeBrowserCachePolicy.canReuseSnapshot(playing: false, age: 29.99, invalidated: false))
        precondition(!YouTubeBrowserCachePolicy.canReuseSnapshot(playing: false, age: 30, invalidated: false))
        precondition(!YouTubeBrowserCachePolicy.canReuseSnapshot(playing: true, age: 1, invalidated: true))
        precondition(!YouTubeBrowserCachePolicy.canReuseSnapshot(playing: true, age: -1, invalidated: false))
        let time = YouTubeBrowserPlayback.times("0:49 / 3:08")!
        precondition(time.0 == 49 && time.1 == 188)
        let long = YouTubeBrowserPlayback.times("1:02:03 / 2:00:00")!
        precondition(long.0 == 3723 && long.1 == 7200)
        for malformed in ["Pause", "foo:01:02 / 3:00", "-1:00 / 3:00", "0:99 / 3:00", "0:01 / nope"] {
            precondition(YouTubeBrowserPlayback.times(malformed) == nil)
        }
        // A browser without Music must not restart a tree scan on every 1s tick.
        var retry = YouTubeBrowserRetryPolicy()
        var scans: [Int] = []
        for second in 0..<120 {
            if retry.allowsAttempt(at: Double(second)) {
                scans.append(second)
                retry.failed(at: Double(second))
            }
        }
        precondition(scans == [0, 5, 15, 35, 65, 95])
        precondition(retry.failures == 4)
        precondition(!retry.allowsAttempt(at: 124.99))
        precondition(retry.allowsAttempt(at: 125))
        // Window changes and explicit commands must bypass a negative cache.
        retry.reset()
        precondition(retry.allowsAttempt(at: 96))
        retry.failed(at: 96)
        precondition(retry.nextAttempt == 101)
        print("PASS: YouTube Music origin isolation, event-invalidated snapshot caching, timeline parsing, and idle scan backoff (6 scans / 120 ticks)")
    }
}
