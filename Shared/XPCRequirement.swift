import Foundation
import Security
import os

/// Builds the code-signing requirement each end of the XPC connection pins the other with.
///
/// Both ends derive it the same way, from the team in the *running binary's own*
/// signature:
///
/// - Properly signed build → require the peer to have the same bundle identifier
///   **and** the same signing team, anchored to Apple. This is the real check.
/// - Ad-hoc or unsigned build → there is no team to require, so fall back to an
///   identifier-only check and say so loudly. Fine for development, not for shipping.
/// - Signed, but with a team that disagrees with `BuildConfiguration` → refuse
///   outright. A build signed by an unexpected team is a mistake worth failing on,
///   not something to paper over.
public enum XPCRequirement {
    public enum Outcome {
        case requirement(String)
        /// The binary is signed by a team other than the expected one.
        case teamMismatch(found: String, expected: String)
    }

    public static func build(peerIdentifier: String,
                             log: Logger) -> Outcome {
        let expected = BuildConfiguration.expectedTeamIdentifier

        guard let team = ownTeamIdentifier() else {
            log.warning("""
            This binary has no team identifier — an ad-hoc or unsigned build. Falling back \
            to an identifier-only XPC check, which is NOT sufficient for a distributed build. \
            Sign with a Developer ID to enable the full check.
            """)
            return .requirement("identifier \"\(peerIdentifier)\"")
        }

        if !expected.isEmpty, team != expected {
            return .teamMismatch(found: team, expected: expected)
        }

        return .requirement("""
        identifier "\(peerIdentifier)" and anchor apple generic \
        and certificate leaf[subject.OU] = "\(team)"
        """)
    }

    /// Reads the team identifier out of the currently running code's signature.
    public static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode,
                                            SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        return (team?.isEmpty == false) ? team : nil
    }

    /// `NSXPCConnection.setCodeSigningRequirement(_:)` raises an Objective-C exception
    /// for a malformed requirement rather than throwing, and an exception raised across
    /// Swift frames is not recoverable. Compiling the string first turns that crash into
    /// an ordinary refused connection.
    public static func isWellFormed(_ requirement: String) -> Bool {
        var parsed: SecRequirement?
        let status = SecRequirementCreateWithString(requirement as CFString, SecCSFlags(), &parsed)
        return status == errSecSuccess && parsed != nil
    }
}
