/// What the app is allowed to claim about which devices work.
///
/// ADR-009 is a one-line rule — *a device is supported only if its presence can be observed
/// reliably through supported APIs* — and SPIKE-009 is currently **PARTIAL**. Its evidence
/// section is unambiguous about what was and was not measured: one ten-minute scan on one
/// Apple Silicon Mac running macOS 26, in which an iPhone, an Apple Watch and an iPad on the
/// same Apple ID were reported in every ten-second window, and one identifier-stability check
/// across two scanner processes 53 seconds apart. Reboots, Bluetooth off/on, 24-hour idle,
/// the distance matrix and the ≤ 10 s silent-gap criterion were **not** measured. No device
/// has met the SUPPORTED bar.
///
/// So the onboarding copy says "observed", never "supported", and names the size of the
/// evidence. Marketing language that outruns the spike is the specific failure ADR-009 was
/// written to prevent, and onboarding is where a user decides how much to trust this app.
public enum SupportedDevices {

    /// The honest note shown on the device-picker step.
    public static let observationNote = """
        Threshold has only been observed with an iPhone, Apple Watch and iPad signed in to the \
        same Apple ID, across a single ten-minute run on one Mac. That is early evidence, not a \
        supported-device list: reboots, Bluetooth being turned off and on, and longer time \
        spans have not been tested yet. Another Mac and AirPods were much less visible in the \
        same run.
        """

    /// One line for the picker's empty state and the settings sheet.
    public static let shortNote = "Observed so far with iPhone, Apple Watch and iPad. Not yet a supported-device list."

    /// Why the list is full of devices the user does not recognise.
    public static let noiseNote = """
        A typical room shows dozens of Bluetooth identifiers, many of which appear for a few \
        seconds and never return. Devices that advertise a name are listed first; turn on \
        "Show every device" if yours has no name.
        """
}
