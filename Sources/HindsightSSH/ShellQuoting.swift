/// Quoting for the one place Hindsight cannot avoid a remote shell.
///
/// ssh has no argv: it concatenates its command arguments with spaces and hands
/// the result to the remote login shell. Everything sent to a server therefore
/// passes through one shell parse, so every value is quoted here rather than
/// interpolated at the call site.
public enum ShellQuoting {
    /// Wraps a value in single quotes, which suppress every form of expansion
    /// in POSIX shells. An embedded single quote is closed, escaped, reopened.
    public static func quote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        if value.allSatisfy(isSafeUnquoted) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func quote(_ values: [String]) -> String {
        values.map(quote).joined(separator: " ")
    }

    private static func isSafeUnquoted(_ character: Character) -> Bool {
        character.isLetter && character.isASCII
            || character.isNumber && character.isASCII
            || "@%_-+=:,./".contains(character)
    }
}
