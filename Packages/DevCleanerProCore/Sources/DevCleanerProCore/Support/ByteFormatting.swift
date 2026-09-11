import Foundation

/// Formats sizes the way the design does.
///
/// The design's formatter is `n >= 1 ? n.toFixed(1) + ' GB' : n > 0 ? round(n * 1024) + ' MB' :
/// '0 B'`, with `n` in gigabytes — so one decimal above a gigabyte, whole megabytes below it, and
/// a plain "0 B" for nothing. Reproduced here rather than using `ByteCountFormatter`, which
/// switches units on its own and would put "1,024 MB" next to "1.0 GB" in the same column.
public enum ByteFormatting {
    private static let gigabyte = 1_073_741_824.0
    private static let megabyte = 1_048_576.0

    /// `nil` renders as an em dash — a size that is genuinely unknown, not zero.
    /// Time Machine snapshots and unreadable protected paths both land here.
    public static func string(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        if bytes <= 0 { return "0 B" }

        let gb = Double(bytes) / gigabyte
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / megabyte
        if mb >= 1 {
            return "\(Int(mb.rounded())) MB"
        }
        let kb = Double(bytes) / 1024
        if kb >= 1 {
            return "\(Int(kb.rounded())) KB"
        }
        return "\(bytes) B"
    }

    /// "12.4 GB / 20.9 GB", for the delete progress header.
    public static func progress(done: Int64, total: Int64) -> String {
        "\(string(done)) / \(string(total))"
    }
}
