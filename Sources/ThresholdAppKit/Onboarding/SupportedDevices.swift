/// What the app is allowed to claim about which devices work.
///
/// ADR-009 is a one-line rule — *a device is supported only if its presence can be observed
/// reliably through supported APIs* — and the copy below is tied to SPIKE-009's own verdicts
/// (docs/spikes/SPIKE-009, third batch 2026-09-03). Apple Watch and iPad reached the spike's
/// one-hour presence bar near the desk (receiving 100%, longest silent gap 6.9 s / 9.9 s) and
/// kept the same identifier for 19 hours, so they are listed as **conditional**: verified near
/// the desk, with the distance, reboot and Bluetooth-toggle scenarios still open. The iPhone
/// was reported in every window of a ten-minute run but did not reappear the next day, so it
/// is **unknown** and is not listed. Nothing has met the unconditional SUPPORTED bar.
///
/// Onboarding is where a user decides how much to trust this app, so the copy names the size
/// of the evidence instead of rounding it up. Marketing language that outruns the spike is the
/// specific failure ADR-009 was written to prevent.
public enum SupportedDevices {

    /// The honest note shown on the device-picker step.
    public static let observationNote = """
        Verified near the desk so far: an Apple Watch and an iPad signed in to this Mac's Apple ID \
        (one hour each, heard in every ten-second window, same identifier the next day). Walking \
        away, restarting devices and toggling Bluetooth have not been tested yet. An iPhone was \
        heard continuously in one ten-minute run but could not be found again the next day, so it \
        is not on the list. Another Mac and AirPods were only intermittently visible.
        """

    /// One line for the picker's empty state and the settings sheet.
    public static let shortNote = "Verified near the desk with Apple Watch and iPad (conditional). iPhone: not yet verified."

    /// Why the list is full of devices the user does not recognise.
    public static let noiseNote = """
        A typical room shows dozens of Bluetooth identifiers, many of which appear for a few \
        seconds and never return. Devices that advertise a name are listed first; turn on \
        "Show every device" if yours has no name.
        """
}
