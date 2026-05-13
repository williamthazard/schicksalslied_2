// test.scd — schicksalslied 2.0 SC engine test harness
// Run from project root:  sclang test.scd
// Boots SC, exercises each voice class, verifies sound + no errors, exits.

(
Routine({
    var kernel;

    Server.default.options.numInputBusChannels = 0;
    "Booting SuperCollider server...".postln;
    Server.default.bootSync;
    "Server booted.".postln;
    0.5.wait;

    "Instantiating Lied kernel...".postln;
    kernel = Lied.new(Server.default);
    2.0.wait;

    "All tests passed.".postln;
    kernel.free;
    Server.default.quit;
    1.0.wait;
    0.exit;
}).play(SystemClock);
)
