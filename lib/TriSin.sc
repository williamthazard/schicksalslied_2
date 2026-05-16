// lib/TriSin.sc — FM voice class (ported from naherinlied with .lag on amp)
TriSin {
    classvar <voiceKeys;

    var <globalParams;
    var <voiceParams;
    var <voiceGroup;
    var <singleVoices;

    *initClass {
        voiceKeys = [\1, \2, \3, \4, \5, \6, \7, \8];
        StartUp.add {
            var s = Server.default;

            s.waitForBoot {

                SynthDef("TriSin", {
                    arg t_gate = 0,
                        mRatio,
                        cRatio,
                        index,
                        iScale,
                        freq,
                        cutoff,
                        resonance,
                        cutoff_env,
                        attack,
                        release,
                        iattack,
                        irelease,
                        cAtk,
                        cRel,
                        ciAtk,
                        ciRel,
                        amp,
                        pan,
                        freq_slew,
                        amp_slew,
                        pan_slew,
                        bus,
                        gran_bus = 0,
                        granular_send = 0;

                    var car, mod, envelope, iEnv, filter, signal;
                    var slewed_freq = freq.lag3(freq_slew);

                    envelope = EnvGen.kr(
                        envelope: Env(
                            [0, 1, 0],
                            times: [attack, release],
                            curve: [cAtk, cRel]),
                        gate: t_gate
                    );

                    iEnv = EnvGen.kr(
                        Env(
                            [index, index * iScale, index],
                            times: [iattack, irelease],
                            curve: [ciAtk, ciRel]),
                        gate: t_gate
                    );

                    mod = SinOsc.ar(slewed_freq * mRatio, mul: slewed_freq * mRatio * iEnv);
                    car = LFTri.ar(slewed_freq * cRatio + mod) * envelope;

                    filter = MoogFF.ar(
                        in: car,
                        freq: Select.kr(cutoff_env > 0, [cutoff, cutoff * envelope]),
                        gain: resonance
                    );

                    signal = Pan2.ar(
                        filter,
                        pan.lag3(pan_slew)
                    );

                    // Granular send: parallel copy to granular chain at independent level.
                    // Uses signal (post-pan) but BEFORE amp scaling, so amp=0 + granular_send=1
                    // gives "granular only" routing without killing the granular signal.
                    Out.ar(gran_bus, signal * granular_send.lag3(0.05));

                    // .lag3 on amp for click-free real-time amp control
                    Out.ar(bus, signal * amp.lag3(amp_slew));
                }).add;
            }
        }
    }

    *new { arg granularBusIdx;
        ^super.new.init(granularBusIdx);
    }

    init { arg granularBusIdx;
        var s = Server.default;

        voiceGroup = Group.new(s);

        globalParams = Dictionary.newFrom([
            \freq, 400,
            \mRatio, 1,
            \cRatio, 1,
            \index, 1,
            \iScale, 5,
            \cutoff, 8000,
            \cutoff_env, 1,
            \resonance, 3,
            \attack, 0,
            \release, 0.4,
            \iattack, 0,
            \irelease, 0.4,
            \cAtk, 4,
            \cRel, (-4),
            \ciAtk, 4,
            \ciRel, (-4),
            \amp, 0.5,
            \pan, 0,
            \freq_slew, 0,
            \amp_slew, 0.05,
            \pan_slew, 0.5,
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

    // Trigger the named voice key (or 'all'). For persistent envelopes,
    // re-triggers the existing Synth if alive; otherwise allocates one.
    playVoice {
        arg voiceKey, freq;
        if (singleVoices[voiceKey].isPlaying, {
            voiceParams[voiceKey][\freq] = freq;
            singleVoices[voiceKey].set(\freq, freq, \t_gate, 1);
        }, {
            voiceParams[voiceKey][\freq] = freq;
            Synth.new("TriSin", voiceParams[voiceKey].getPairs, singleVoices[voiceKey]);
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
    // This is the cross-cutting "real-time amp control" idiom: changing amp
    // here audibly fades currently-sounding notes, not just future ones.
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

    freeAllNotes {
        voiceGroup.freeAll;
    }

    free {
        voiceGroup.free;
    }
}
