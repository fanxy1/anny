import Foundation

enum TerminalService {
    static let sshExecutable = "/usr/bin/ssh"

    static func sshArguments(_ host: WatchedHost) -> [String] {
        [
            "-tt",
            "-p", "\(host.port)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UpdateHostKeys=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            host.sshTarget,
        ]
    }

    /// `KEY=VALUE` 列表，给 PTY 里的 ssh 用。
    static func processEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let path = env["PATH"], !path.isEmpty {
            env["PATH"] = path + ":" + extraPath
        } else {
            env["PATH"] = extraPath
        }
        if env["HOME"] == nil {
            env["HOME"] = NSHomeDirectory()
        }
        if env["SSH_AUTH_SOCK"] == nil, let sock = launchctlValue("SSH_AUTH_SOCK"), !sock.isEmpty {
            env["SSH_AUTH_SOCK"] = sock
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["CLICOLOR"] = "1"
        env["CLICOLOR_FORCE"] = "1"
        if env["LANG"] == nil || env["LANG"]?.isEmpty == true {
            env["LANG"] = "zh_CN.UTF-8"
        }
        return env.map { "\($0.key)=\($0.value)" }
    }

    private static func launchctlValue(_ key: String) -> String? {
        let result = try? ProcessRun.run("/bin/launchctl", arguments: ["getenv", key], timeout: 2)
        guard let result, result.status == 0 else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
