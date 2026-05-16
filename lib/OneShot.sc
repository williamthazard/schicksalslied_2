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
    var <buffer;

    *initClass {
        voiceKeys = [\1, \2, \3, \4, \5, \6, \7, \8];
        StartUp.add {
            var s = Server.default;

            s.waitForBoot {

                SynthDef("OneShot", {
                    arg t_gate = 0,
                        rate = 1,
                        cutoff = 12000,
                        cutoff_slew = 0.05,
                        resonance = 1,
                        amp = 0.5,
                        amp_slew = 0.05,
                        pan = 0,
                        pan_slew = 0.5,
                        buf = 0,
                        bus = 0,
                        gran_bus = 0,
                        granular_send = 0;

                    var sig = PlayBuf.ar(1, buf, BufRateScale.ir(buf) * rate, t_gate);
                    var filter = MoogFF.ar(sig, cutoff.lag3(cutoff_slew), resonance);
                    var signal = Pan2.ar(filter, pan.lag3(pan_slew));

                    // Granular send: parallel copy to granular chain at independent level.
                    // Uses signal (post-pan) but BEFORE amp scaling, so amp=0 + granular_send=1
                    // gives "granular only" routing without killing the granular signal.
                    Out.ar(gran_bus, signal * granular_send.lag3(0.05));

                    // Single amp multiplication with .lag3 for click-free
                    // real-time control. No doneAction:2 — synth is persistent.
                    Out.ar(bus, signal * amp.lag3(amp_slew));
                }).add;
            }
        }
    }

    *new { arg buf, granularBusIdx;
        ^super.new.init(buf, granularBusIdx);
    }

    init { arg buf, granularBusIdx;
        var s = Server.default;

        buffer = buf;
        voiceGroup = Group.new(s);

        globalParams = Dictionary.newFrom([
            \cutoff, 12000,
            \cutoff_slew, 0.05,
            \resonance, 1,
            \amp, 0.5,
            \amp_slew, 0.05,
            \pan, 0,
            \pan_slew, 0.5,
            \buf, buf.bufnum,
            \rate, 1,
            \bus, 0,
            \gran_bus, granularBusIdx ? 0,
            \granular_send, 0;
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
        arg voiceKey, rate;
        voiceParams[voiceKey][\rate] = rate;
        if (singleVoices[voiceKey].isPlaying, {
            singleVoices[voiceKey].set(\rate, rate, \t_gate, 1);
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

    // Free voice subgroups + update voiceParams[*][\bus] so the next trigger
    // allocates fresh with the new output bus. Needed because Out.ar samples
    // \bus at construction; .set on a running synth updates the control value
    // but doesn't reroute audio. We use the same free+recreate pattern as
    // resetVoices: simply calling freeAll would leave the subgroup Group node
    // alive (isPlaying returns true), routing the next trigger into the
    // re-trigger branch instead of fresh-allocate.
    reroute {
        arg busVal;
        var s = Server.default;
        voiceKeys.do({ arg vK;
            voiceParams[vK][\bus] = busVal;
            if (singleVoices[vK].notNil) {
                singleVoices[vK].free;
            };
            singleVoices[vK] = Group.new(voiceGroup);
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
