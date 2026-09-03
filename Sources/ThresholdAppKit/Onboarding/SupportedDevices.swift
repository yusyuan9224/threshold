/// What the app is allowed to claim about which devices work.
///
/// ADR-009 is a one-line rule — *a device is supported only if its presence can be observed
/// reliably through supported APIs* — and the copy below is tied to SPIKE-009's own verdicts
/// (docs/spikes/SPIKE-009, fourth batch 2026-09-03, the first run with distance controlled).
/// An iPhone kept locked with its screen off was heard in every ten-second window at all three
/// distances — on the desk, in a pocket across the room, and in the next room behind a closed
/// door — with signal strength falling cleanly with distance, so it is listed first and is the
/// only class verified at leaving distance. An Apple Watch matched it near the desk but lost a
/// sixth of its windows at eight metres, so its entry says where it stops working rather than
/// rounding that off. An iPad has only the earlier one-hour run at an uncontrolled distance.
/// Nothing has met the unconditional SUPPORTED bar.
///
/// Onboarding is where a user decides how much to trust this app, so the copy names the size
/// of the evidence instead of rounding it up. Marketing language that outruns the spike is the
/// specific failure ADR-009 was written to prevent.
public enum SupportedDevices {

    /// The honest note shown on the device-picker step.
    public static let observationNote = """
        Best tested: an iPhone signed in to this Mac's Apple ID. Locked, screen off, it was heard \
        in every ten-second window on the desk, in a pocket three metres away, and in the next \
        room behind a closed door, and it kept the same identifier a day later. An Apple Watch \
        matched that on and near the desk but was heard in only 84% of windows from the next \
        room, with one silent stretch of 26 seconds — good evidence that you are here, not that \
        you have left, so pick it alongside a phone rather than on its own. An iPad has been \
        verified only near the desk. Restarting devices, toggling Bluetooth and re-pairing have \
        not been tested yet on any of them. Another Mac and AirPods were only intermittently \
        visible and are not listed.
        """

    /// One line for the picker's empty state and the settings sheet.
    public static let shortNote =
        "Verified at desk, pocket and next-room distance with an iPhone (conditional). "
        + "Apple Watch and iPad: verified near the desk only."

    /// Why the list is full of devices the user does not recognise.
    public static let noiseNote = """
        A typical room shows dozens of Bluetooth identifiers, many of which appear for a few \
        seconds and never return. Devices that advertise a name are listed first; turn on \
        "Show every device" if yours has no name.
        """
}
