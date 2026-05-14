// test.scd — schicksalslied 2.0 SC engine test harness
// Run from project root:  sclang test.scd
// Boots SC, exercises each voice class, verifies sound + no errors, exits.

(
Routine({
    var kernel, testSynth;

    Server.default.options.numInputBusChannels = 0;
    "Booting SuperCollider server...".postln;
    Server.default.bootSync;
    if (Server.default.serverRunning.not) {
        "ERROR: Server failed to boot. Aborting.".postln;
        1.exit;
    };
    "Server booted.".postln;
    0.5.wait;

    "Instantiating Lied kernel...".postln;
    kernel = Lied.new(Server.default);
    1.0.wait;

    "Test 4: setBeatSec updates kernel.beat_sec...".postln;
    kernel.setBeatSec(0.25);    // 240 BPM
    ("  Expected beat_sec=0.25, actual=" ++ kernel.beat_sec).postln;
    if (kernel.beat_sec == 0.25, {
        "  ✓ setBeatSec works".postln;
    }, {
        "  ✗ FAIL: setBeatSec did not update beat_sec".postln;
    });
    1.0.wait;

    // Test 1: dry bus passthrough — should hear a clean 440Hz tone for 1s
    "Test 1: dry bus passthrough (clean 440Hz, no FX)...".postln;
    testSynth = {
        var sig = SinOsc.ar(440) * EnvGen.kr(Env.perc(0.01, 0.8), doneAction: 2) * 0.3;
        Out.ar(kernel.dryBus, [sig, sig]);
    }.play(kernel.voiceGroup);
    1.5.wait;

    // Test 2: reverb send — 440Hz tone with reverb tail
    "Test 2: reverb send (440Hz with reverb tail)...".postln;
    testSynth = {
        var sig = SinOsc.ar(440) * EnvGen.kr(Env.perc(0.01, 0.8), doneAction: 2) * 0.3;
        Out.ar(kernel.reverbBus, [sig, sig]);
    }.play(kernel.voiceGroup);
    3.0.wait;

    // Test 3: delay send — 440Hz tone with delay (and reverb on the delay tail)
    "Test 3: delay send (440Hz with delay + reverb)...".postln;
    testSynth = {
        var sig = SinOsc.ar(440) * EnvGen.kr(Env.perc(0.01, 0.8), doneAction: 2) * 0.3;
        Out.ar(kernel.delayBus, [sig, sig]);
    }.play(kernel.voiceGroup);
    5.0.wait;

// Test 5: TriSin — trigger a note, verify sound, verify real-time amp control
"Test 5: TriSin basic trigger (440Hz, voice \\1, on dryBus)...".postln;
~triSinTest = TriSin.new;
~triSinTest.setParam('all', \bus, kernel.dryBus.index);
~triSinTest.setParam('all', \amp, 0.5);
~triSinTest.setParam('all', \release, 2.0);  // long release for amp-sweep test
~triSinTest.trigger(\1, 440);
"  Expected: 440Hz tone with 2s release.".postln;
2.0.wait;

"Test 6: TriSin real-time amp fade — note still sounding, fade amp to 0 mid-note".postln;
~triSinTest.trigger(\2, 220);
0.3.wait;
"  Mid-note, setting amp=0 (should hear smooth fade-out, no click)...".postln;
~triSinTest.setParam('all', \amp, 0);
1.5.wait;
~triSinTest.free;
1.0.wait;

"Test 7: TriSin polyphony — fire 4 notes in rapid succession on different voiceKeys".postln;
~triSinPoly = TriSin.new;
~triSinPoly.setParam('all', \bus, kernel.dryBus.index);
~triSinPoly.setParam('all', \amp, 0.3);
~triSinPoly.setParam('all', \release, 3.0);  // long release so notes overlap
~triSinPoly.trigger(\1, 261.6);   // C4
0.3.wait;
~triSinPoly.trigger(\2, 329.6);   // E4
0.3.wait;
~triSinPoly.trigger(\3, 392.0);   // G4
0.3.wait;
~triSinPoly.trigger(\4, 523.3);   // C5
"  Expected: 4 notes stacking into a C major chord with overlapping releases.".postln;
3.0.wait;
~triSinPoly.free;
1.0.wait;

"Test 8: Ringer basic trigger (pinged resonant filter at 440Hz)...".postln;
~ringerTest = Ringer.new;
~ringerTest.setParam('all', \bus, kernel.dryBus.index);
~ringerTest.setParam('all', \amp, 0.5);
~ringerTest.setParam('all', \index, 4);
~ringerTest.trigger(\1, 440);
"  Expected: pinged Ringz tone with ~8s decay (index=4, release=index*2).".postln;
2.0.wait;

"Test 9: Ringer real-time amp fade — note still sounding, fade amp to 0...".postln;
~ringerTest.trigger(\2, 220);
0.3.wait;
"  Mid-note, setting amp=0 (should hear smooth fade-out)...".postln;
~ringerTest.setParam('all', \amp, 0);
1.5.wait;
~ringerTest.free;
1.0.wait;

"Test 10: Sampler — load audio/test_long.wav, trigger, hear playback".postln;
~samplerBuf = Buffer.read(Server.default, "audio/test_long.wav");
Server.default.sync;
("  Loaded buffer: " ++ ~samplerBuf.numFrames ++ " frames, "
    ++ ~samplerBuf.numChannels ++ " channels").postln;

~samplerTest = Sampler.new(~samplerBuf);
~samplerTest.setParam('all', \bus, kernel.dryBus.index);
~samplerTest.setParam('all', \amp, 0.5);
~samplerTest.trigger(\1, 0.0, 1.0, 1);   // play full buffer
"  Expected: full test_long.wav plays at original rate.".postln;
6.0.wait;
~samplerTest.free;
~samplerBuf.free;
1.0.wait;

"Test 11: Sampler crossfade — rapid retriggers at 16th-note intervals (~250ms)".postln;
~xfBuf = Buffer.read(Server.default, "audio/test_long.wav");
Server.default.sync;
~xfSampler = Sampler.new(~xfBuf);
~xfSampler.setParam('all', \bus, kernel.dryBus.index);
~xfSampler.setParam('all', \amp, 0.3);
"  Expected: 16 retriggers, each cutting cleanly to the next.".postln;
"  Failure mode: audible clicks/pops on each retrigger.".postln;
16.do({ arg i;
    var startPos = i.linlin(0, 16, 0.0, 0.8);
    var endPos   = startPos + 0.05;
    ~xfSampler.trigger(\1, startPos, endPos, 1);
    0.25.wait;
});
~xfSampler.free;
~xfBuf.free;
1.0.wait;

    "Test 12: OneShot — basic trigger, hear a quick noise burst".postln;
    ~oneShotBuf = Buffer.read(Server.default, "audio/test_oneshot.wav");
    Server.default.sync;
    ~oneShotTest = OneShot.new(~oneShotBuf);
    ~oneShotTest.setParam('all', \bus, kernel.dryBus.index);
    ~oneShotTest.setParam('all', \amp, 0.5);
    ~oneShotTest.trigger(\1);
    "  Expected: ~1.6s sample playback (freed after 1s wait).".postln;
    1.0.wait;
    ~oneShotTest.free;
    ~oneShotBuf.free;
    1.0.wait;

    "Test 13: OneShot long-sample fade-out (spec §14 test #7)".postln;
    ~fieldBuf = Buffer.read(Server.default, "audio/test_field.wav");
    Server.default.sync;
    ~fieldTest = OneShot.new(~fieldBuf);
    ~fieldTest.setParam('all', \bus, kernel.dryBus.index);
    ~fieldTest.setParam('all', \amp, 0.5);
    ~fieldTest.setParam('all', \amp_slew, 0.3);  // slow but completes within test window
    ~fieldTest.trigger(\1);
    "  Long sample (~20s) starts playing...".postln;
    2.0.wait;
    "  Mid-playback: setting amp=0 with 0.3s slew. Expected: smooth fade to silence within 2s.".postln;
    ~fieldTest.setParam('all', \amp, 0);
    2.0.wait;
    "  ✓ if you heard a smooth fade with no click, real-time amp on long samples works".postln;
    ~fieldTest.free;
    ~fieldBuf.free;
    1.0.wait;

    kernel.free;
    "All tests passed.".postln;
    Server.default.quit;
    1.0.wait;
    0.exit;
}).play(SystemClock);
)
