import Foundation
import Security

nonisolated enum MCPCredentials {
    // A private, owner-only file avoids Keychain permission prompts when users
    // build unsigned copies. Never include this file in exports or diagnostics.
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whisp/Automation", isDirectory: true)
    }

    static func loadOrCreate() throws -> String {
        let file = directory.appendingPathComponent("token")
        if FileManager.default.fileExists(atPath: file.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let value = String(data: try Data(contentsOf: file), encoding: .utf8),
                  value.count == 64, value.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
                throw WhispFailure(message: "The AI access token could not be read. Use New token to replace it.")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return value
        }
        return try replace()
    }

    static func replace() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw WhispFailure(message: "Could not create a secure AI access token.")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent("token")
        try Data(token.utf8).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return token
    }

    static func matches(_ supplied: String, _ expected: String) -> Bool {
        let a = Array(supplied.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
