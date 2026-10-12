import Foundation

/// Detects SSH login commands + password-like strings and builds a Suggested merge.
enum SuggestionEngine {
    /// How far back (in time) to look for the other half of a pair.
    static let pairWindow: TimeInterval = 3 * 60
    /// How many recent text items to scan (in addition to the time window).
    static let recentScanLimit = 12

    static func isSSHCommand(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 400 else { return false }
        // Must look like an ssh invocation (not prose mentioning "ssh").
        // Examples: `ssh root@10.0.0.1 -p 22`, `ssh -p 30285 user@host`, `ssh host`
        let pattern = #"(?i)^\s*ssh(\s+\-[A-Za-z]+(\s+\S+)?)*\s+\S+"#
        guard t.range(of: pattern, options: .regularExpression) != nil else { return false }
        // Prefer user@host or -p <port>, but bare `ssh hostname` is also OK if short/single-line.
        if t.contains("@") { return true }
        if t.range(of: #"(?i)\-p\s+\d+"#, options: .regularExpression) != nil { return true }
        // Single-line, few tokens, no CJK — likely a command.
        if t.contains(where: { $0.isNewline }) { return false }
        if t.unicodeScalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF }) { return false }
        let tokens = t.split(whereSeparator: { $0.isWhitespace })
        return tokens.count >= 2 && tokens.count <= 8
    }

    static func isPasswordLike(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 8, t.count <= 128 else { return false }
        // Single line, no spaces (passwords almost never contain whitespace).
        if t.contains(where: { $0.isWhitespace || $0.isNewline }) { return false }
        // Not a URL / email / path / ssh command.
        if isSSHCommand(t) { return false }
        let lower = t.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("ftp://") { return false }
        if t.contains("://") { return false }
        if t.contains("@") && t.contains(".") && !t.contains(where: { "!#$%^&*()+=[]{}|;:'\",<>?/`~\\".contains($0) }) {
            // Likely email without strong password punctuation.
            return false
        }
        if t.hasPrefix("/") || t.hasPrefix("~") { return false }
        // No CJK prose.
        if t.unicodeScalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF }) { return false }

        var hasLetter = false, hasDigit = false, hasSymbol = false
        for ch in t.unicodeScalars {
            if CharacterSet.letters.contains(ch) { hasLetter = true }
            else if CharacterSet.decimalDigits.contains(ch) { hasDigit = true }
            else { hasSymbol = true }
        }
        // Need mixed charset: letters+digits, or letters/digits + punctuation.
        let classes = [hasLetter, hasDigit, hasSymbol].filter { $0 }.count
        guard classes >= 2 else { return false }
        // Reject low-entropy looking strings (all same char, or only hex of short length without symbols).
        if Set(t).count < max(4, t.count / 8) { return false }
        return true
    }

    /// Given a newly captured item and recent history (newest first), return a Suggested merge if a pair is found.
    /// Rules: only SSH-then-password pairs (the password must be copied after the SSH command);
    /// each password and each SSH command pairs at most once. The new password is consumed by the
    /// most recent preceding SSH command, provided no other password was copied in between
    /// (which would mean that SSH command already paired with that password).
    static func suggestedMerge(newItem: ClipItem, history: [ClipItem]) -> ClipItem? {
        guard newItem.kind == .text, let newText = newItem.plainText, !newItem.isSuggested else { return nil }
        guard isPasswordLike(newText) else { return nil }

        let cutoff = Date().addingTimeInterval(-pairWindow)
        let candidates = history
            .filter { $0.kind == .text && !$0.isSuggested && $0.id != newItem.id }
            .filter { $0.createdAt >= cutoff && $0.createdAt <= newItem.createdAt }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(recentScanLimit)

        let pass = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        for other in candidates {
            guard let otherText = other.plainText else { continue }
            if isPasswordLike(otherText) { return nil }   // earlier SSH already consumed by that password
            guard isSSHCommand(otherText) else { continue }
            let ssh = otherText.trimmingCharacters(in: .whitespacesAndNewlines)
            if ssh.contains(pass) { return nil }
            return ClipItem(
                kind: .text,
                createdAt: Date(),
                text: "\(ssh) \(pass)",
                sourceAppName: "Suggested",
                sourceAppBundleID: Store.suggestedBundleID,
                isSuggested: true
            )
        }
        return nil
    }

    static func selfTest() {
        var fails: [String] = []
        func check(_ name: String, _ ok: Bool) { if !ok { fails.append(name) } }

        check("ssh1", isSSHCommand("ssh root@10.26.6.88 -p 30285"))
        check("ssh2", isSSHCommand("ssh -p 30285 user@host.example.com"))
        check("ssh3", isSSHCommand("ssh ubuntu@192.168.1.1"))
        check("ssh-no", !isSSHCommand("I used ssh yesterday to log in"))
        check("ssh-no2", !isSSHCommand("https://example.com"))

        check("pass1", isPasswordLike("LfC^JyL@@TCDf0pQVWl!A*Za?%cM5bEA"))
        check("pass2", isPasswordLike("aB3$kL9mNpQ2"))
        check("pass-no-short", !isPasswordLike("abc"))
        check("pass-no-space", !isPasswordLike("hello world"))
        check("pass-no-url", !isPasswordLike("https://example.com/path"))
        check("pass-no-ssh", !isPasswordLike("ssh root@host"))
        check("pass-no-alpha", !isPasswordLike("abcdefghij"))

        if fails.isEmpty {
            AppLog.info("SuggestionEngine self-test PASS")
        } else {
            AppLog.error("SuggestionEngine self-test FAIL: \(fails.joined(separator: ", "))")
        }
    }
}
