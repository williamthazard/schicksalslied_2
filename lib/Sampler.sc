// lib/Sampler.sc — long-file sampler with Phasor + BufRd crossfade
// Ported from naherinlied's \PlayBufPlayer SynthDef (naherinlied.scd:98-189),
// wrapped in a class for consistent retrigger / param-update idiom.
Sampler {
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

                SynthDef(\Sampler, {
                    arg bufnum = 0,
                        rate = 1,
                        start = 0,
                        end = 1,
                        t_trig = 0,
                        loops = 1,
                        amp = 0.2,
                        amp_slew = 0.05,
                        pan = 0,
                        pan_slew = 1,
                        cutoff = 12000,
                        cutoff_slew = 0.05,
                        resonance = 1,
                        rateSlew = 0.1,
                        bus = 0;
                    var snd, snd2, pos, pos2, frames, duration, env, sig,
                        startA, endA, startB, endB, crossfade, aOrB, filtered;

                    aOrB = ToggleFF.kr(t_trig);
                    startA = Latch.kr(start, aOrB);
                    endA   = Latch.kr(end,   aOrB);
                    startB = Latch.kr(start, 1 - aOrB);
                    endB   = Latch.kr(end,   1 - aOrB);
                    crossfade = Lag.ar(K2A.ar(aOrB), 0.1);

                    rate = Lag.kr(rate, rateSlew) * BufRateScale.kr(bufnum);
                    frames = BufFrames.kr(bufnum);
                    duration = frames * (end - start) / rate.abs / s.sampleRate * loops;

                    env = EnvGen.ar(
                        Env.new(
                            levels: [0, amp, amp, 0],
                            times:  [0.005, max(0.001, duration - 0.105), 0.1]),
                        gate: t_trig,
                    );

                    pos = Phasor.ar(
                        trig: aOrB,
                        rate: rate,
                        start: (((rate > 0) * startA) + ((rate < 0) * endA)) * frames,
                        end:   (((rate > 0) * endA)   + ((rate < 0) * startA)) * frames,
                        resetPos: (((rate > 0) * startA) + ((rate < 0) * endA)) * frames,
                    );

                    snd = BufRd.ar(
                        numChannels: 2,
                        bufnum: bufnum,
                        phase: pos,
                        interpolation: 4,
                    );

                    pos2 = Phasor.ar(
                        trig: (1 - aOrB),
                        rate: rate,
                        start: (((rate > 0) * startB) + ((rate < 0) * endB)) * frames,
                        end:   (((rate > 0) * endB)   + ((rate < 0) * startB)) * frames,
                        resetPos: (((rate > 0) * startB) + ((rate < 0) * endB)) * frames,
                    );

                    snd2 = BufRd.ar(
                        numChannels: 2,
                        bufnum: bufnum,
                        phase: pos2,
                        interpolation: 4,
                    );

                    filtered = MoogFF.ar(
                        in: (crossfade * snd) + ((1 - crossfade) * snd2) * env,
                        freq: cutoff.lag3(cutoff_slew),
                        gain: resonance);

                    sig = Balance2.ar(filtered[0], filtered[1], pan.lag3(pan_slew));

                    // .lag3 on amp for click-free real-time amp control
                    Out.ar(bus, LeakDC.ar(sig) * amp.lag3(amp_slew));
                }).add;
            }
        }
    }

    *new { arg buf;
        ^super.new.init(buf);
    }

    init { arg buf;
        var s = Server.default;

        buffer = buf;
        voiceGroup = Group.new(s);

        globalParams = Dictionary.newFrom([
            \bufnum, buf.bufnum,
            \rate, 1,
            \start, 0,
            \end, 1,
            \loops, 1,
            \amp, 0.5,
            \amp_slew, 0.05,
            \pan, 0,
            \pan_slew, 1,
            \cutoff, 12000,
            \cutoff_slew, 0.05,
            \resonance, 1,
            \rateSlew, 0.1,
            \bus, 0;
        ]);
        singleVoices = Dictionary.new;
        voiceParams = Dictionary.new;
        voiceKeys.do({
            arg voiceKey;
            singleVoices[voiceKey] = Group.new(voiceGroup);
            voiceParams[voiceKey] = Dictionary.newFrom(globalParams);
        });
    }

    // Trigger the named voice with a play window and rate.
    triggerVoice {
        arg voiceKey, startPos, endPos, rate = 1;
        if (singleVoices[voiceKey].isPlaying, {
            voiceParams[voiceKey][\start] = startPos;
            voiceParams[voiceKey][\end]   = endPos;
            voiceParams[voiceKey][\rate]  = rate;
            singleVoices[voiceKey].set(\start, startPos, \end, endPos, \rate, rate, \t_trig, 1);
        }, {
            voiceParams[voiceKey][\start] = startPos;
            voiceParams[voiceKey][\end]   = endPos;
            voiceParams[voiceKey][\rate]  = rate;
            Synth.new(\Sampler, voiceParams[voiceKey].getPairs, singleVoices[voiceKey]);
            singleVoices[voiceKey].set(\t_trig, 1);
            NodeWatcher.register(singleVoices[voiceKey], true);
        });
    }

    trigger {
        arg voiceKey, startPos, endPos, rate = 1;
        if (voiceKey == 'all', {
            voiceKeys.do({ arg vK; this.triggerVoice(vK, startPos, endPos, rate); });
        }, {
            this.triggerVoice(voiceKey, startPos, endPos, rate);
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
    // Used by Lied.silenceAllSamplers for post-K1-panic recovery: the
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
