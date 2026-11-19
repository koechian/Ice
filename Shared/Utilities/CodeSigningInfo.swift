//
//  CodeSigningInfo.swift
//  Shared
//

import Foundation
import Security
import XPC

/// Information about the code signature of the current process.
enum CodeSigningInfo {
    /// The team identifier of the current process's code signature, or `nil`
    /// if the process is ad-hoc signed or not signed by a developer team.
    static let teamIdentifier: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess else {
            return nil
        }
        let dictionary = information as? [String: Any]
        return dictionary?[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// The peer requirement for XPC connections between the app and its
    /// bundled services.
    ///
    /// Builds signed by a developer team require peers from the same team.
    /// Locally built copies have no team identifier, so `.isFromSameTeam()`
    /// would reject every connection. Those builds rely on the system rule
    /// that a bundled XPC service accepts connections only from its
    /// containing app.
    @available(macOS 26.0, *)
    static var servicePeerRequirement: XPCPeerRequirement? {
        teamIdentifier == nil ? nil : .isFromSameTeam()
    }
}
