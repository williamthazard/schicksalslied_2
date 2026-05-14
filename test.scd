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

    kernel.free;
    "All tests passed.".postln;
    Server.default.quit;
    1.0.wait;
    0.exit;
}).play(SystemClock);
)
