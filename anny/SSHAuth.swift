import Foundation
import Security

enum HostSecretStore {
    static let service = "cn.fanxy.anny"

    static func save(_ password: String, for id: UUID) {
        delete(for: id)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id.uuidString,
            kSecValueData: Data(password.utf8),
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func hasPassword(for id: UUID) -> Bool {
        password(for: id) != nil
    }

    static func password(for id: UUID) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id.uuidString,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    static func delete(for id: UUID) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum SSHAuth {
    static func sshFlags(hasPassword: Bool) -> [String] {
        var flags = [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "NumberOfPasswordPrompts=1",
        ]
        if hasPassword {
            flags += [
                "-o", "PreferredAuthentications=publickey,password,keyboard-interactive",
                "-o", "PasswordAuthentication=yes",
                "-o", "KbdInteractiveAuthentication=yes",
            ]
        } else {
            flags += [
                "-o", "BatchMode=yes",
                "-o", "PreferredAuthentications=publickey",
            ]
        }
        return flags
    }

    static func processEnvironment(hostID: UUID, base: [String: String]? = nil) -> [String: String] {
        var env = base ?? ProcessInfo.processInfo.environment
        guard HostSecretStore.hasPassword(for: hostID) else { return env }
        env["SSH_ASKPASS"] = askpassURL.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = "."
        env["ANNY_SSH_ACCOUNT"] = hostID.uuidString
        return env
    }

    static func environmentPairs(hostID: UUID, base: [String: String]) -> [String] {
        processEnvironment(hostID: hostID, base: base).map { "\($0.key)=\($0.value)" }
    }

    private static var askpassURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = root.appendingPathComponent("anny", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("askpass")
        let body = """
        #!/bin/sh
        exec /usr/bin/security find-generic-password -s '\(HostSecretStore.service)' -a "$ANNY_SSH_ACCOUNT" -w
        """
        if (try? String(contentsOf: url, encoding: .utf8)) != body {
            try? body.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        return url
    }
}
