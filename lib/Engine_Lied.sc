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

        "Engine_Lied alloc complete.".postln;
    }

    free {
        kernel.free;
    }
}
