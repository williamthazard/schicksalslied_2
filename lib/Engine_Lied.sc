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
        this.addCommand(\set_mic_amp,         "f", { arg msg; kernel.setMicAmp(msg[1]); });
        this.addCommand(\set_mic_dry_amp,     "f", { arg msg; kernel.setMicDryAmp(msg[1]); });
        this.addCommand(\set_granular_out_amp,"f", { arg msg; kernel.setGranularOutAmp(msg[1]); });
        this.addCommand(\set_fb_amp,          "f", { arg msg; kernel.setFbPatchAmp(msg[1]); });
        this.addCommand(\set_fb_balance,      "f", { arg msg; kernel.setFbPatchBalance(msg[1]); });
        this.addCommand(\set_fb_hpf,          "f", { arg msg; kernel.setFbPatchHpFreq(msg[1]); });
        this.addCommand(\set_fb_noise,        "f", { arg msg; kernel.setFbPatchNoiseLevel(msg[1]); });
        this.addCommand(\set_fb_sine_level,   "f", { arg msg; kernel.setFbPatchSineLevel(msg[1]); });
        this.addCommand(\set_fb_sine_hz,      "f", { arg msg; kernel.setFbPatchSineHz(msg[1]); });

        "Engine_Lied alloc complete.".postln;
    }

    free {
        kernel.free;
    }
}
