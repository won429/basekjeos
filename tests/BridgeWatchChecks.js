// Deterministic JXA watch tests with mocked Objective-C objects; no media commands.
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const source = fs.readFileSync(process.argv[2], 'utf8');
const cover = 'A'.repeat(300000);
const payloads = [
    { title: '첫 곡', artist: '가수', elapsedTime: 0, playbackRate: 1, artworkDataBase64: cover },
    { title: '첫 곡', artist: '가수', elapsedTime: 0.2, playbackRate: 1, artworkDataBase64: cover },
    { title: '첫 곡', artist: '가수', elapsedTime: 1, playbackRate: 1, artworkDataBase64: cover },
    { title: '첫 곡', artist: '가수', elapsedTime: 1, playbackRate: 0, artworkDataBase64: cover },
    null,
    { title: '다음 곡', artist: '가수', elapsedTime: 0, playbackRate: 1, artworkDataBase64: cover },
    { title: '다음 곡', artist: '가수', elapsedTime: 0, playbackRate: 1, artworkDataBase64: null },
    { title: '다음 곡', artist: '가수', elapsedTime: 1, playbackRate: 1, artworkDataBase64: cover },
];
let index = 0;
const output = [];
const $ = text => ({dataUsingEncoding: () => text});
$.NSUTF8StringEncoding = 4;
$.NSFileHandle = {fileHandleWithStandardOutput: {writeData: line => output.push(JSON.parse(line))}};
$.NSRunLoop = {currentRunLoop: {runUntilDate: () => index++}};
$.NSDate = {dateWithTimeIntervalSinceNow: () => 0};
const ctx = vm.createContext({$, ObjC: {import(){}, unwrap: v => v}});
vm.runInContext(source, ctx);
ctx.nowPlayingPayload = () => payloads[index];
ctx.watchNowPlaying(payloads.length);
assert.deepStrictEqual(output.map(p => p && [p.title, p.elapsedTime, p.playbackRate]),
    payloads.filter((_, i) => i !== 1).map(p => p && [p.title, p.elapsedTime, p.playbackRate]));
assert.strictEqual(output[0].artworkDataBase64, cover);
assert.strictEqual(output[1].artworkDataBase64, null);
assert.strictEqual(output[2].artworkDataBase64, null);
assert.strictEqual(output[4].artworkDataBase64, cover);
assert.strictEqual(output[6].artworkDataBase64, cover);
let encoded = 0;
function data(value) { return {value, isEqualToData: other => value === other.value,
    base64EncodedStringWithOptions: () => { encoded++; return value; }}; }
const dictionary = value => ({ valueForKey: () => data(value) });
assert.strictEqual(ctx.base64DataForKey(dictionary('abc'), 'art'), 'abc');
assert.strictEqual(ctx.base64DataForKey(dictionary('abc'), 'art'), 'abc');
assert.strictEqual(ctx.base64DataForKey(dictionary('def'), 'art'), 'def');
assert.strictEqual(encoded, 2);
const baselineBytes = Buffer.byteLength(JSON.stringify(payloads.filter((_, i) => i !== 1)));
const optimizedBytes = Buffer.byteLength(JSON.stringify(output));
console.log(`PASS: metadata/seek/pause/track/null transitions, artwork retention + reappearance, encoding cache; fixture bytes ${baselineBytes} -> ${optimizedBytes}`);
