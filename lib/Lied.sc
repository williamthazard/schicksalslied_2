// lib/Lied.sc — schicksalslied 2.0 SC kernel (skeleton)
Lied {
    var <server;

    *new { arg server;
        ^super.new.init(server);
    }

    init { arg inServer;
        server = inServer ? Server.default;
        "Lied initialized.".postln;
    }

    free {
        "Lied freed.".postln;
    }
}
