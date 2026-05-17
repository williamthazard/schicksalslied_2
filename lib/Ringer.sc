// lib/Ringer.sc — pinged resonant voice class (perc envelope, doneAction:2)
Ringer {
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

                SynthDef("Ringer", {
                    arg stopGate = 1,
                        index,
                        freq,
                        amp,
                        pan,
                        freq_slew,
                        amp_slew,
                        pan_slew,
                        dry_bus = 0, reverb_bus = 0, delay_bus = 0, gran_bus = 0,
                        dry_send = 1, reverb_send = 0, delay_send = 0, granular_send = 0;

                    var envelope, sig, signal, ampSig;

                    envelope = EnvGen.kr(
                        envelope: Env.perc(
                            attackTime: 0.01,
                            releaseTime: index.abs * 2,
                            level: 1),
                        gate: stopGate,
                        doneAction: 2
                    );

                    // amp used here AND in Out (below) — effective output is amp²;
                    // inherited from naherinlied donor, intentional, not a bug
                    sig = Ringz.ar(
                        Impulse.ar(0),
                        freq.lag3(freq_slew),
                        index,
                        amp
                    ) * envelope;

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
        }
    }

    *new { arg dryBusIdx, reverbBusIdx, delayBusIdx, granularBusIdx;
        ^super.new.init(dryBusIdx, reverbBusIdx, delayBusIdx, granularBusIdx);
    }

    init { arg dryBusIdx, reverbBusIdx, delayBusIdx, granularBusIdx;
        var s = Server.default;

        voiceGroup = Group.new(s);

        globalParams = Dictionary.newFrom([
            \freq, 400,
            \index, 3,
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

    // Stop-gate the previous (if any), then fire a fresh Synth.
    // Ringer's envelope has doneAction:2 so it self-frees at release.
    playVoice {
        arg voiceKey, freq;
        singleVoices[voiceKey].set(\stopGate, -1.05);
        voiceParams[voiceKey][\freq] = freq;
        Synth.new("Ringer", voiceParams[voiceKey].getPairs, singleVoices[voiceKey]);
    }

    trigger {
        arg voiceKey, freq;
        if (voiceKey == 'all', {
            voiceKeys.do({ arg vK; this.playVoice(vK, freq); });
        }, {
            this.playVoice(voiceKey, freq);
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

    freeAllNotes {
        voiceGroup.set(\stopGate, -1.05);
    }

    free {
        voiceGroup.free;
    }
}
