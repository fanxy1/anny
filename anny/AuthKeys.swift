import CryptoKit
import Foundation

enum AuthKeys {
    static func parseFile(_ raw: String) -> AuthKeysSnapshot {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.isEmpty {
            return AuthKeysSnapshot(rawLines: [], rows: [], fetchedAt: Date())
        }
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var rows: [AuthKeyRow] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            rows.append(parseLine(line, index: index))
        }
        return AuthKeysSnapshot(rawLines: lines, rows: rows, fetchedAt: Date())
    }

    static func parsePasted(_ raw: String) -> (line: String?, error: String?) {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if lines.isEmpty {
            return (nil, "请粘贴公钥")
        }
        if lines.count > 1 {
            return (nil, "一次只加一把密钥")
        }
        let row = parseLine(lines[0], index: 0)
        guard row.valid else {
            return (nil, "不是合法的公钥")
        }
        return (row.raw, nil)
    }

    static func removingLines(_ snapshot: AuthKeysSnapshot, indices: Set<Int>) -> String {
        encodeFile(
            snapshot.rawLines.enumerated().compactMap { index, line in
                indices.contains(index) ? nil : line
            }
        )
    }

    static func encodeFile(_ lines: [String]) -> String {
        if lines.isEmpty { return "" }
        let body = lines.joined(separator: "\n")
        return body.hasSuffix("\n") ? body : body + "\n"
    }

    static func parseLine(_ raw: String, index: Int) -> AuthKeyRow {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = tokenize(trimmed)
        guard let typeIndex = tokens.firstIndex(where: { keyTypes.contains($0) }),
              typeIndex + 1 < tokens.count,
              let data = decodeBlob(tokens[typeIndex + 1]),
              !data.isEmpty
        else {
            return AuthKeyRow(
                lineIndex: index,
                keyType: "",
                typeLabel: "无效",
                comment: trimmed,
                fingerprint: "—",
                raw: trimmed,
                valid: false
            )
        }
        let keyType = tokens[typeIndex]
        let comment = tokens[(typeIndex + 2)...].joined(separator: " ")
        return AuthKeyRow(
            lineIndex: index,
            keyType: keyType,
            typeLabel: typeLabel(keyType),
            comment: comment,
            fingerprint: fingerprint(data),
            raw: trimmed,
            valid: true
        )
    }

    static func fingerprint(_ blob: Data) -> String {
        let digest = SHA256.hash(data: blob)
        let b64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(b64)"
    }

    static func typeLabel(_ keyType: String) -> String {
        var s = keyType
        if let at = s.firstIndex(of: "@") {
            s = String(s[..<at])
        }
        s = s.replacingOccurrences(of: "-cert-v01", with: "")
        if s.hasPrefix("sk-ssh-") {
            return "sk-" + String(s.dropFirst(7))
        }
        if s.hasPrefix("sk-ecdsa-") {
            return "sk-ecdsa"
        }
        if s.hasPrefix("ssh-") {
            s = String(s.dropFirst(4))
        }
        if s.hasPrefix("ecdsa-") {
            return "ecdsa"
        }
        return s
    }

    private static let keyTypes: Set<String> = [
        "sk-ssh-ed25519-cert-v01@openssh.com",
        "sk-ecdsa-sha2-nistp256-cert-v01@openssh.com",
        "ssh-ed25519-cert-v01@openssh.com",
        "ssh-rsa-cert-v01@openssh.com",
        "ecdsa-sha2-nistp521-cert-v01@openssh.com",
        "ecdsa-sha2-nistp384-cert-v01@openssh.com",
        "ecdsa-sha2-nistp256-cert-v01@openssh.com",
        "sk-ssh-ed25519@openssh.com",
        "sk-ecdsa-sha2-nistp256@openssh.com",
        "ecdsa-sha2-nistp521",
        "ecdsa-sha2-nistp384",
        "ecdsa-sha2-nistp256",
        "ssh-ed25519",
        "ssh-rsa",
        "ssh-dss",
        "ssh-xmss@openssh.com",
    ]

    private static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        for ch in line {
            if ch == "\"" {
                inQuote.toggle()
                current.append(ch)
            } else if ch.isWhitespace, !inQuote {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func decodeBlob(_ blob: String) -> Data? {
        var s = blob.trimmingCharacters(in: .whitespacesAndNewlines)
        let pad = (4 - s.count % 4) % 4
        if pad > 0 {
            s += String(repeating: "=", count: pad)
        }
        return Data(base64Encoded: s)
    }
}
