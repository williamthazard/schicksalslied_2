// lib/OneShot.sc — persistent one-shot sampler with .lag3 on amp + cutoff
// Upgrade of naherinlied's OneShot: fixes the double-amp-multiplication
// bug (1.x multiplied amp twice in the signal chain), makes the synth
// persistent (no doneAction:2) so long samples can be faded out
// mid-playback via group.set(\amp, 0), adds .lag3 smoothing on amp AND
// cutoff.
OneShot {
    classvar <voiceKeys;

    var <globalParams;
    var <voiceParams;
    var <voiceGroup;
    var <singleVoices;
    var <buffers;

    *initClass {
        voiceKeys = [\1, \2, \3, \4, \5, \6, \7, \8];
    }

    // Added by Lied.init once Crone has booted the server — never from a
    // StartUp hook, which runs at every sclang start and could boot scsynth
    // before Crone had set it up.
    *addSynthDefs {
        SynthDef("OneShot", {
            arg t_gate = 0,
                rate = 1,
                cutoff = 12000,
                cutoff_slew = 0.05,
                resonance = 1,
                amp = 0.5,
                amp_slew = 0.05,
                amp_scale = 1.0,
                pan = 0,
                pan_slew = 0.5,
                buf = 0,
                dry_bus = 0, reverb_bus = 0, delay_bus = 0, gran_bus = 0,
                dry_send = 1, reverb_send = 0, delay_send = 0, granular_send = 0;

            var sig, filter, signal, ampSig;
            // Buffers are always 2-channel (Lied reads mono files into
            // both channels). Balance2 on a dual-mono pair gives the
            // same levels Pan2 gave the mono signal at every pan
            // position; stereo files keep their image.
            sig = PlayBuf.ar(2, buf, BufRateScale.kr(buf) * rate, t_gate);
            filter = MoogFF.ar(sig, cutoff.lag3(cutoff_slew), resonance);
            signal = Balance2.ar(filter[0], filter[1], pan.lag3(pan_slew));

            // Post-fader: amp scales all 4 sends. No doneAction:2 — synth is persistent.
            ampSig = amp.lag3(amp_slew) * amp_scale;
            Out.ar(dry_bus,    signal * ampSig * dry_send.lag3(0.05));
            Out.ar(reverb_bus, signal * ampSig * reverb_send.lag3(0.05));
            Out.ar(delay_bus,  signal * ampSig * delay_send.lag3(0.05));
            Out.ar(gran_bus,   signal * ampSig * granular_send.lag3(0.05));
        }).add;
    }

    *new { arg buf, dryBusIdx, reverbBusIdx, delayBusIdx, granularBusIdx;
        ^super.new.init(buf, dryBusIdx, reverbBusIdx, delayBusIdx, granularBusIdx);
    }

    init { arg buf, dryBusIdx, reverbBusIdx, delayBusIdx, granularBusIdx;
        var s = Server.default;

        buffers = if (buf.isArray) { buf } { [buf] };
        voiceGroup = Group.new(s);

        globalParams = Dictionary.newFrom([
            \cutoff, 12000,
            \cutoff_slew, 0.05,
            \resonance, 1,
            \amp, 0.5,
            \amp_slew, 0.05,
            \pan, 0,
            \pan_slew, 0.5,
            \buf, buffers[0].bufnum,
            \amp_scale, 1.0,
            \rate, 1,
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

    playVoice {
        arg voiceKey;
        if (singleVoices[voiceKey].isPlaying, {
            singleVoices[voiceKey].set(\t_gate, 1);
        }, {
            Synth.new("OneShot", voiceParams[voiceKey].getPairs, singleVoices[voiceKey]);
            singleVoices[voiceKey].set(\t_gate, 1);
            NodeWatcher.register(singleVoices[voiceKey], true);
        });
    }

    // Trigger a voice with a specific rate, set + retrigger in one OSC message.
    // Used by Lied.triggerOneShot for one-shot cells where the rate comes
    // from the cell's value_mode runtime (per Sub-plan B's sequencer).
    triggerWithRate {
        arg voiceKey, rate = 1, bufIdx = 0, ampScale = 1.0;
        var targetBuf = buffers.wrapAt(bufIdx);
        voiceParams[voiceKey][\rate] = rate;
        voiceParams[voiceKey][\buf] = targetBuf.bufnum;
        voiceParams[voiceKey][\amp_scale] = ampScale;
        if (singleVoices[voiceKey].isPlaying, {
            singleVoices[voiceKey].set(\rate, rate, \buf, targetBuf.bufnum, \amp_scale, ampScale, \t_gate, 1);
        }, {
            Synth.new("OneShot", voiceParams[voiceKey].getPairs, singleVoices[voiceKey]);
            singleVoices[voiceKey].set(\t_gate, 1);
            NodeWatcher.register(singleVoices[voiceKey], true);
        });
    }

    trigger {
        arg voiceKey;
        if (voiceKey == 'all', {
            voiceKeys.do({ arg vK; this.playVoice(vK); });
        }, {
            this.playVoice(voiceKey);
        });
    }

    buffer {
        ^buffers[0];
    }

    adjustVoice {
        arg voiceKey, paramKey, paramValue;
        singleVoices[voiceKey].set(paramKey, paramValue);
        voiceParams[voiceKey][paramKey] = paramValue;
    }

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

    // Free all voice sub-groups and recreate them empty.
    // Used by Lied.silenceAllOneShots for post-K1-panic recovery: the
    // freshly-created sub-groups are unregistered with NodeWatcher so
    // `singleVoices[voiceKey].isPlaying` returns false on next trigger,
    // forcing the fresh-allocate branch and a new Synth.
    resetVoices {
        var s = Server.default;
        voiceKeys.do({ arg voiceKey;
            if (singleVoices[voiceKey].notNil) {
                singleVoices[voiceKey].free;
            };
            singleVoices[voiceKey] = Group.new(voiceGroup);
        });
    }

    free {
        voiceGroup.free;
    }
}
