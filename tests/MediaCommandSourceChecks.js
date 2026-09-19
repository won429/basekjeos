// Append to NowPlayingBridge.js with its run function renamed to runBridgeAction.
// No actual media commands are sent by this regression check.
function run() {
    let payload = null;
    const dispatched = [];
    loadMediaRemote = function () { return true; };
    nowPlayingPayload = function () { return payload; };
    sendCommand = function (command) { dispatched.push(command); return true; };
    isYouTubeMusicSafariWebApp = function (bundle) {
        return bundle === 'com.apple.safari.webapp.verified-music';
    };
    function check(condition, message) { if (!condition) throw new Error(message); }
    payload = { sourceApp: 'YT Music', bundleIdentifier: 'com.apple.Safari.WebApp.7EC7712F-7A24-4185-9797-DA23CB02F16F' };
    [2, 5, 4].forEach(function (command) {
        const response = JSON.parse(runBridgeAction(['send', String(command)]));
        check(response.success === true, 'YT Music control was rejected');
    });
    check(dispatched.join(',') === '2,5,4', 'Incorrect playback command mapping');
    check(isYouTubeMusicPayload({ sourceApp: 'YouTube Music' }), 'Full app name');
    check(isYouTubeMusicPayload({ sourceApp: 'My Music', bundleIdentifier: 'com.apple.Safari.WebApp.verified-music' }), 'Renamed Safari music app');
    check(isYouTubeMusicPayload({ bundleIdentifier: 'com.google.Chrome.app.cinhimbnkkaeohfgghhklpknlkffjgod' }), 'Chrome music app');
    check(isYouTubeMusicPayload({ externalContentIdentifier: 'https://music.youtube.com/watch?v=example' }), 'Music content URL');
    [null, {sourceApp:'QuickTime Player',bundleIdentifier:'com.apple.QuickTimePlayerX'}, {sourceApp:'VLC',bundleIdentifier:'org.videolan.vlc'}, {sourceApp:'Safari'}, {sourceApp:'YouTube'}, {sourceApp:'Netflix'},
     {sourceApp:'My Music',bundleIdentifier:'com.apple.Safari.WebApp.unrelated'}].forEach(function (other) {
        payload = other;
        const response = JSON.parse(runBridgeAction(['send', '2']));
        check(response.ignored === true && response.success === false, 'Unrelated session must not receive commands');
    });
    check(dispatched.length === 3, 'Command leaked into an unrelated session');
    return 'Media source checks passed: YT Music controls, renamed Safari app, Chrome, content URLs, unrelated sessions blocked';
}
