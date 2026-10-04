import CryptoKit
import Foundation

/// Digest helper shared by the binary store and anything that needs to compare
/// a local payload against what a server reports.
public enum BinaryStoreDigest {
    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
