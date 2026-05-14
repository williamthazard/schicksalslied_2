// lib/Lied.sc — schicksalslied 2.0 SC kernel
Lied {
    var <server;
    var <dryBus, <reverbBus, <delayBus;
    var <voiceGroup, <fxGroup;
    var <delaySynth, <reverbSynth, <outSynth;

    *new { arg server;
        ^super.new.init(server);
    }

    init { arg inServer;
        server = inServer ? Server.default;
        "Lied init: allocating buses + master FX...".postln;

        // --- Audio buses ---
        // dryBus       = main output (mirrors naherinlied's ~fb)
        // reverbBus    = pre-reverb send (mirrors naherinlied's c)
        // delayBus     = pre-delay send  (mirrors naherinlied's b)
        dryBus    = Bus.audio(server, 2);
        reverbBus = Bus.audio(server, 2);
        delayBus  = Bus.audio(server, 2);

        // --- Group hierarchy ---
        //   server default group
        //     └── voiceGroup (all voice instances will add to this; populated lazily later)
        //     └── fxGroup    (runs after voiceGroup, contains delay + reverb synths)
        voiceGroup = Group.new(server);
        fxGroup    = Group.after(voiceGroup);

        // --- SynthDefs: master FX ---
        // Delay reads delayBus → output to dryBus AND reverbBus (delay → reverb chain)
        SynthDef(\liedDelay, {
            arg inBus, dryOut, reverbOut, delayTime = 0.3, feedback = 0.5,
                amp = 1.0, amp_slew = 0.1;
            var sig = In.ar(inBus, 2);
            var del = CombL.ar(sig, 2.0, delayTime, feedback);
            Out.ar(dryOut,    del * amp.lag(amp_slew));
            Out.ar(reverbOut, del * amp.lag(amp_slew));
        }).add;

        // Reverb reads reverbBus → output to dryBus
        SynthDef(\liedReverb, {
            arg inBus, dryOut, room = 0.5, damp = 0.5,
                amp = 1.0, amp_slew = 0.1;
            var sig = In.ar(inBus, 2);
            var rev = FreeVerb.ar(sig, 1.0, room, damp);
            Out.ar(dryOut, rev * amp.lag(amp_slew));
        }).add;

        // Pass dryBus through to main output (0)
        SynthDef(\liedOut, {
            arg inBus, amp = 1.0, amp_slew = 0.1;
            var sig = In.ar(inBus, 2);
            Out.ar(0, sig * amp.lag(amp_slew));
        }).add;

        server.sync;

        // --- Instantiate master FX (persistent) ---
        delaySynth  = Synth.new(\liedDelay,
            [\inBus, delayBus, \dryOut, dryBus, \reverbOut, reverbBus],
            fxGroup);
        reverbSynth = Synth.new(\liedReverb,
            [\inBus, reverbBus, \dryOut, dryBus],
            fxGroup);
        outSynth    = Synth.new(\liedOut,
            [\inBus, dryBus],
            Group.after(fxGroup));

        "Lied initialized.".postln;
    }

    free {
        delaySynth.free;
        reverbSynth.free;
        outSynth.free;
        voiceGroup.free;
        fxGroup.free;
        dryBus.free;
        reverbBus.free;
        delayBus.free;
        "Lied freed.".postln;
    }
}
