ObjC.import('Foundation');
ObjC.import('AppKit');

function unwrap(value) {
    try {
        if (value === undefined || value === null) return null;
        return ObjC.unwrap(value);
    } catch (_) {
        return null;
    }
}

function valueForKey(dictionary, key) {
    try {
        return unwrap(dictionary.valueForKey(key));
    } catch (_) {
        return null;
    }
}

let cachedArtworkData = null;
let cachedArtworkBase64 = null;
let artworkRevision = 0;
function base64DataForKey(dictionary, key) {
    try {
        const data = dictionary.valueForKey(key);
        if (!data) return null;
        if (!cachedArtworkData || !data.isEqualToData(cachedArtworkData)) {
            cachedArtworkData = data;
            cachedArtworkBase64 = unwrap(data.base64EncodedStringWithOptions(0));
            artworkRevision++;
        }
        return cachedArtworkBase64;
    } catch (_) {
        return null;
    }
}

function loadMediaRemote() {
    const framework = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
    if (!framework) return false;
    framework.load;
    return true;
}

function nowPlayingPayload() {
    const request = $.NSClassFromString('MRNowPlayingRequest');
    if (!request) return null;

    try {
        const item = request.localNowPlayingItem;
        const information = item.nowPlayingInfo;
        const title = valueForKey(information, 'kMRMediaRemoteNowPlayingInfoTitle');
        if (!title) return null;

        let elapsed = valueForKey(information, 'kMRMediaRemoteNowPlayingInfoElapsedTime');
        try {
            const calculated = unwrap(item.metadata.calculatedPlaybackPosition);
            if (typeof calculated === 'number' && Number.isFinite(calculated)) elapsed = calculated;
        } catch (_) {}

        let sourceApp = '브라우저';
        let bundleIdentifier = null;
        try {
            const client = request.localNowPlayingPlayerPath.client;
            sourceApp = unwrap(client.displayName) || sourceApp;
            bundleIdentifier = unwrap(client.parentApplicationBundleIdentifier) || unwrap(client.bundleIdentifier);
        } catch (_) {}

        return {
            title: title,
            artist: valueForKey(information, 'kMRMediaRemoteNowPlayingInfoArtist'),
            album: valueForKey(information, 'kMRMediaRemoteNowPlayingInfoAlbum'),
            duration: valueForKey(information, 'kMRMediaRemoteNowPlayingInfoDuration'),
            elapsedTime: elapsed,
            playbackRate: valueForKey(information, 'kMRMediaRemoteNowPlayingInfoPlaybackRate'),
            sourceApp: sourceApp,
            bundleIdentifier: bundleIdentifier,
            contentItemIdentifier: valueForKey(information, 'kMRMediaRemoteNowPlayingInfoContentItemIdentifier'),
            externalContentIdentifier: valueForKey(information, 'kMRMediaRemoteNowPlayingInfoExternalContentIdentifier'),
            artworkDataBase64: base64DataForKey(information, 'kMRMediaRemoteNowPlayingInfoArtworkData'),
            artworkMIMEType: valueForKey(information, 'kMRMediaRemoteNowPlayingInfoArtworkMIMEType'),
            artworkIdentifier: valueForKey(information, 'kMRMediaRemoteNowPlayingInfoArtworkIdentifier')
        };
    } catch (_) {
        return null;
    }
}

function sendCommand(command) {
    try {
        const controllerClass = $.NSClassFromString('MRNowPlayingController');
        const controller = controllerClass.localRouteController;
        const options = $.NSDictionary.alloc.init;
        controller.sendCommandOptionsCompletion(command, options, null);
        return true;
    } catch (_) {
        return false;
    }
}

// Match the source checks used for metadata in MediaRemoteClient. Safari web
// apps can have user-defined names, so also verify their installed manifest.
function isYouTubeMusicSafariWebApp(bundleIdentifier) {
    if (!bundleIdentifier.startsWith('com.apple.safari.webapp.')) return false;
    try {
        const applications = $.NSWorkspace.sharedWorkspace.runningApplications;
        for (let i = 0; i < applications.count; i++) {
            const application = applications.objectAtIndex(i);
            if (String(unwrap(application.bundleIdentifier) || '').toLowerCase() !== bundleIdentifier) continue;
            const bundle = $.NSBundle.bundleWithURL(application.bundleURL);
            const info = bundle.infoDictionary;
            const manifestURL = String(valueForKey(info, 'WKManifestURL') || '').toLowerCase();
            const manifest = info.objectForKey('Manifest');
            const startURL = String(valueForKey(manifest, 'start_url') || '').toLowerCase();
            return manifestURL.includes('music.youtube.com') || startURL.includes('music.youtube.com');
        }
    } catch (_) {}
    return false;
}

function isYouTubeMusicPayload(payload) {
    if (!payload) return false;
    const sourceApp = String(payload.sourceApp || '').toLowerCase();
    const bundleIdentifier = String(payload.bundleIdentifier || '').toLowerCase();
    const contentIdentity = [
        payload.contentItemIdentifier,
        payload.externalContentIdentifier
    ].filter(Boolean).join(' ').toLowerCase();

    return sourceApp.includes('youtube music')
        || sourceApp.includes('yt music')
        || bundleIdentifier.includes('cinhimbnkkaeohfgghhklpknlkffjgod')
        || isYouTubeMusicSafariWebApp(bundleIdentifier)
        || contentIdentity.includes('music.youtube.com')
        || contentIdentity.includes('youtube music');
}

// Keep the entitled reader alive instead of launching a new interpreter for every poll.
// Service the run loop between samples so MediaRemote can deliver fresh metadata.
function watchNowPlaying(maxSamples) {
    let previous = null;
    let previousArtworkIdentity = null;
    const output = $.NSFileHandle.fileHandleWithStandardOutput;
    for (let sample = 0; !maxSamples || sample < maxSamples; sample++) {
        const payload = nowPlayingPayload();
        const signaturePayload = payload ? Object.assign({}, payload, {
            elapsedTime: Math.floor(Number(payload.elapsedTime) || 0),
            artworkDataBase64: payload.artworkDataBase64 ? artworkRevision : null
        }) : null;
        const signature = JSON.stringify(signaturePayload);
        // Emit an unchanged heartbeat every two seconds. The app uses it to
        // distinguish a healthy quiet stream from a helper that is alive but
        // stuck inside MediaRemote.
        if (signature !== previous || sample % 10 === 0) {
            const identity = payload ? JSON.stringify([
                payload.title, payload.artist, payload.album, payload.bundleIdentifier,
                payload.contentItemIdentifier, payload.externalContentIdentifier,
                payload.artworkDataBase64 ? artworkRevision : null
            ]) : null;
            // The receiver retains the cover; elapsed-time updates need only metadata.
            const message = payload && identity === previousArtworkIdentity
                ? Object.assign({}, payload, { artworkDataBase64: null }) : payload;
            const line = $(JSON.stringify(message) + '\n').dataUsingEncoding($.NSUTF8StringEncoding);
            previousArtworkIdentity = identity;
            output.writeData(line);
            previous = signature;
        }
        $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.2));
    }
}

function run(arguments) {
    if (!loadMediaRemote()) return JSON.stringify(null);

    const action = arguments[0] || 'get';
    if (action === 'watch') {
        watchNowPlaying(Number(arguments[1]) || 0);
        return;
    }
    if (action === 'send') {
        if (!isYouTubeMusicPayload(nowPlayingPayload())) {
            return JSON.stringify({ success: false, ignored: true });
        }
        const command = Number(arguments[1]);
        const success = sendCommand(command);
        if (success) {
            // MediaRemote sends the command asynchronously over XPC. Keep the
            // entitled osascript process alive long enough to flush it.
            $.NSThread.sleepForTimeInterval(0.35);
        }
        return JSON.stringify({ success: success });
    }

    return JSON.stringify(nowPlayingPayload());
}
