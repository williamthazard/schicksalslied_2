// lib/Sine.sc — pure sine wave voice class with AR envelope
Sine {
    classvar <voiceKeys;

    var <globalParams;
    var <voiceParams;
    var <voiceGroup;
    var <singleVoices;

    *initClass {
        voiceKeys = [\1, \2, \3, \4, \5, \6, \7, \8];
    }

    // Added by Lied.init once Crone has booted the server — never from a
    // StartUp hook, which runs at every sclang start and could boot scsynth
    // before Crone had set it up.
    *addSynthDefs {
        SynthDef("Sine", {
            arg t_gate = 0,
                freq = 400,
                hz_offset = 0,
                attack = 0.01,
                release = 0.4,
                cAtk = 4,
                cRel = (-4),
                amp = 0.5,
                pan = 0,
                freq_slew = 0,
                amp_slew = 0.05,
                pan_slew = 0.5,
                dry_bus = 0, reverb_bus = 0, delay_bus = 0, gran_bus = 0,
                dry_send = 1, reverb_send = 0, delay_send = 0, granular_send = 0;

            var sig, signal, envelope, ampSig;
            var slewed_freq = max(0.1, freq + hz_offset).lag3(freq_slew);

            envelope = EnvGen.kr(
                envelope: Env(
                    [0, 1, 0],
                    times: [attack, release],
                    curve: [cAtk, cRel]),
                gate: t_gate
            );

            sig = SinOsc.ar(slewed_freq) * envelope;

            signal = Pan2.ar(
                sig,
                pan.lag3(pan_slew)
            );

            // Post-fader: amp scales all 4 sends
            ampSig = amp.lag3(amp_slew);
            Out.ar(dry_bus,    signal * ampSig * dry_send.lag3(0.05));
            Out.ar(reverb_bus, signal * ampSig * reverb_send.lag3(0.05));
            Out.ar(delay_bus,  signal * ampSig * delay_send.lag3(0.05));
            Out.ar(gran_bus,   signal * ampSig * granular_send.lag3(0.05));
        }).add;
    }

    *new { arg dryBusIdx, reverbBusIdx, delayBusIdx, granularBusIdx;
        ^super.new.init(dryBusIdx, reverbBusIdx, delayBusIdx, granularBusIdx);
    }

    init { arg dryBusIdx, reverbBusIdx, delayBusIdx, granularBusIdx;
        var s = Server.default;

        voiceGroup = Group.new(s);

        globalParams = Dictionary.newFrom([
            \freq, 400,
            \hz_offset, 0,
            \attack, 0.01,
            \release, 0.4,
            \cAtk, 4,
            \cRel, (-4),
            \amp, 0.5,
            \pan, 0,
            \freq_slew, 0,
            \amp_slew, 0.05,
            \pan_slew, 0.5,
            \dry_bus, dryBusIdx ? 0,
            \reverb_bus, reverbBusIdx ? 0,
            \delay_bus, delayBusIdx ? 0,
            \gran_bus, granularBusIdx ? 0,
            \dry_send, 1,
            \reverb_send, 0,
            \delay_send, 0,
            \granular_send, 0,
        ]);
        singleVoices = Dictionary.new;
        voiceParams = Dictionary.new;
        voiceKeys.do({
            arg voiceKey;
            singleVoices[voiceKey] = Group.new(voiceGroup);
            voiceParams[voiceKey] = Dictionary.newFrom(globalParams);
        });
    }

    // Trigger the named voice key (or 'all'). For persistent envelopes,
    // re-triggers the existing Synth if alive; otherwise allocates one.
    playVoice {
        arg voiceKey, freq;
        if (singleVoices[voiceKey].isPlaying, {
            voiceParams[voiceKey][\freq] = freq;
            singleVoices[voiceKey].set(\freq, freq, \t_gate, 1);
        }, {
            voiceParams[voiceKey][\freq] = freq;
            Synth.new("Sine", voiceParams[voiceKey].getPairs, singleVoices[voiceKey]);
            singleVoices[voiceKey].set(\t_gate, 1);
            NodeWatcher.register(singleVoices[voiceKey], true);
        });
    }

    trigger {
        arg voiceKey, freq;
        if (voiceKey == 'all', {
            voiceKeys.do({ arg vK; this.playVoice(vK, freq); });
        }, {
            this.playVoice(voiceKey, freq);
        });
    }

    // Set a param on one voice (Synth-level) AND cache in voiceParams (for next alloc).
    adjustVoice {
        arg voiceKey, paramKey, paramValue;
        singleVoices[voiceKey].set(paramKey, paramValue);
        voiceParams[voiceKey][paramKey] = paramValue;
    }

    // Set param across all 8 voices in one go via voiceGroup.set (1 OSC msg).
    setParam {
        arg voiceKey, paramKey, paramValue;
        if (voiceKey == 'all', {
            voiceGroup.set(paramKey, paramValue);
            voiceKeys.do({
                arg vK;
                voiceParams[vK][paramKey] = paramValue;
            });
        }, {
            this.adjustVoice(voiceKey, paramKey, paramValue);
        });
    }

    freeAllNotes {
        voiceGroup.freeAll;
    }

    free {
        voiceGroup.free;
    }
}
