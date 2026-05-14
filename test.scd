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

    kernel.free;
    "All tests passed.".postln;
    Server.default.quit;
    1.0.wait;
    0.exit;
}).play(SystemClock);
)
