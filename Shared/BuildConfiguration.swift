import Foundation

/// Build-time identity constants.
public enum BuildConfiguration {
    /// The Apple Developer Team ID this app is expected to be signed with.
    ///
    /// Must match `DEVELOPMENT_TEAM` in `Config/Signing.xcconfig`. It is not a secret —
    /// a Team ID is embedded in every signed binary Apple ships — but it is load-bearing:
    /// the helper compares it against the team in its own signature and refuses to serve
    /// anything if the two disagree, which turns a mis-signed build into a clean refusal
    /// rather than a helper that quietly trusts the wrong signer.
    ///
    /// Empty means "unsigned / ad-hoc development build"; see `XPCRequirement`.
    public static let expectedTeamIdentifier = "CYY72W5P5F"
}
