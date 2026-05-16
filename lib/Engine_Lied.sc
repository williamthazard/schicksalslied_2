// lib/Engine_Lied.sc — schicksalslied 2.0 Crone wrapper (skeleton)
// The full command surface lands in Sub-plan B. This skeleton just instantiates
// the Lied kernel so Norns will recognize the engine when loaded.
Engine_Lied : CroneEngine {
    var kernel;

    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }

    alloc {
        kernel = Lied.new(context.server);

        this.addCommand(\set_beat_sec, "f", { arg msg;
            kernel.setBeatSec(msg[1]);
        });
        this.addCommand(\set_out_amp,         "f", { arg msg; kernel.setOutAmp(msg[1]); });
        this.addCommand(\set_delay_time,  "f", { arg msg; kernel.setDelayTime(msg[1]); });
        this.addCommand(\set_delay_decay, "f", { arg msg; kernel.setDelayDecay(msg[1]); });
        this.addCommand(\set_delay_amp,   "f", { arg msg; kernel.setDelayAmp(msg[1]); });
        this.addCommand(\set_reverb_room, "f", { arg msg; kernel.setReverbRoom(msg[1]); });
        this.addCommand(\set_reverb_damp, "f", { arg msg; kernel.setReverbDamp(msg[1]); });
        this.addCommand(\set_reverb_amp,  "f", { arg msg; kernel.setReverbAmp(msg[1]); });
        this.addCommand(\set_mic_amp,         "f", { arg msg; kernel.setMicAmp(msg[1]); });
        this.addCommand(\set_mic_dry_amp,     "f", { arg msg; kernel.setMicDryAmp(msg[1]); });
        this.addCommand(\set_granular_out_amp,"f", { arg msg; kernel.setGranularOutAmp(msg[1]); });
        this.addCommand(\set_fb_amp,          "f", { arg msg; kernel.setFbPatchAmp(msg[1]); });
        this.addCommand(\set_fb_balance,      "f", { arg msg; kernel.setFbPatchBalance(msg[1]); });
        this.addCommand(\set_fb_hpf,          "f", { arg msg; kernel.setFbPatchHpFreq(msg[1]); });
        this.addCommand(\set_fb_noise,        "f", { arg msg; kernel.setFbPatchNoiseLevel(msg[1]); });
        this.addCommand(\set_fb_sine_level,   "f", { arg msg; kernel.setFbPatchSineLevel(msg[1]); });
        this.addCommand(\set_fb_sine_hz,      "f", { arg msg; kernel.setFbPatchSineHz(msg[1]); });
        this.addCommand(\set_grain_pan_rate, "if", { arg msg;
            kernel.setGrainPanRate(msg[1].asInteger, msg[2]);
        });
        this.addCommand(\set_grain_cutoff_rate, "if", { arg msg;
            kernel.setGrainCutoffRate(msg[1].asInteger, msg[2]);
        });
        this.addCommand(\set_grain_res_rate, "if", { arg msg;
            kernel.setGrainResRate(msg[1].asInteger, msg[2]);
        });

        // -----------------------------------------------------------------
        // Voice instance lifecycle (per row-2 cell, cellId is string)
        // -----------------------------------------------------------------

        this.addCommand(\trisin_alloc, "s", { arg msg;
            kernel.allocTriSin(msg[1].asSymbol);
        });
        this.addCommand(\trisin_free, "s", { arg msg;
            kernel.freeTriSin(msg[1].asSymbol);
        });
        this.addCommand(\trisin_trigger, "sif", { arg msg;
            var cellId = msg[1].asSymbol;
            var voiceKey = msg[2].asInteger.asString.asSymbol;
            var freq = msg[3];
            kernel.triggerTriSin(cellId, voiceKey, freq);
        });
        this.addCommand(\trisin_set_param, "ssf", { arg msg;
            kernel.setTriSinParam(msg[1].asSymbol, msg[2].asSymbol, msg[3]);
        });
        this.addCommand(\trisin_reroute, "sf", { arg msg;
            kernel.rerouteTriSin(msg[1].asSymbol, msg[2]);
        });

        this.addCommand(\ringer_alloc, "s", { arg msg;
            kernel.allocRinger(msg[1].asSymbol);
        });
        this.addCommand(\ringer_free, "s", { arg msg;
            kernel.freeRinger(msg[1].asSymbol);
        });
        this.addCommand(\ringer_trigger, "sif", { arg msg;
            var cellId = msg[1].asSymbol;
            var voiceKey = msg[2].asInteger.asString.asSymbol;
            var freq = msg[3];
            kernel.triggerRinger(cellId, voiceKey, freq);
        });
        this.addCommand(\ringer_set_param, "ssf", { arg msg;
            kernel.setRingerParam(msg[1].asSymbol, msg[2].asSymbol, msg[3]);
        });
        this.addCommand(\ringer_reroute, "sf", { arg msg;
            kernel.rerouteRinger(msg[1].asSymbol, msg[2]);
        });

        // -----------------------------------------------------------------
        // Sampler instance lifecycle (per row-4/6 slot, integer 1-16)
        // -----------------------------------------------------------------

        this.addCommand(\sampler_load, "is", { arg msg;
            kernel.loadSampler(msg[1].asInteger, msg[2].asString);
        });
        this.addCommand(\sampler_clear, "i", { arg msg;
            kernel.clearSampler(msg[1].asInteger);
        });
        this.addCommand(\sampler_trigger, "iifff", { arg msg;
            var slot = msg[1].asInteger;
            var voiceKey = msg[2].asInteger.asString.asSymbol;
            var startPos = msg[3];
            var endPos = msg[4];
            var rate = msg[5];
            kernel.triggerSampler(slot, voiceKey, startPos, endPos, rate);
        });
        this.addCommand(\sampler_set_param, "isf", { arg msg;
            kernel.setSamplerParam(msg[1].asInteger, msg[2].asSymbol, msg[3]);
        });
        this.addCommand(\sampler_reroute, "if", { arg msg;
            kernel.rerouteSampler(msg[1].asInteger, msg[2]);
        });

        // -----------------------------------------------------------------
        // OneShot instance lifecycle (per row-8 slot, integer 1-13)
        // -----------------------------------------------------------------

        this.addCommand(\oneshot_load, "is", { arg msg;
            kernel.loadOneShot(msg[1].asInteger, msg[2].asString);
        });
        this.addCommand(\oneshot_clear, "i", { arg msg;
            kernel.clearOneShot(msg[1].asInteger);
        });
        this.addCommand(\oneshot_trigger, "iif", { arg msg;
            var slot = msg[1].asInteger;
            var voiceKey = msg[2].asInteger.asString.asSymbol;
            var rate = msg[3];
            kernel.triggerOneShot(slot, voiceKey, rate);
        });
        this.addCommand(\oneshot_set_param, "isf", { arg msg;
            kernel.setOneShotParam(msg[1].asInteger, msg[2].asSymbol, msg[3]);
        });
        this.addCommand(\oneshot_reroute, "if", { arg msg;
            kernel.rerouteOneShot(msg[1].asInteger, msg[2]);
        });

        this.addCommand(\silence_all_samplers, "", { arg msg;
            kernel.silenceAllSamplers;
        });
        this.addCommand(\silence_all_oneshots, "", { arg msg;
            kernel.silenceAllOneShots;
        });
        this.addCommand(\free_granular, "", { arg msg;
            kernel.freeGranularChain;
        });

        "Engine_Lied alloc complete.".postln;
    }

    free {
        kernel.free;
    }
}
