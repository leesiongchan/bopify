public enum PressingSeed {
    public static func hash(_ uri: String) -> UInt64 {
        uri.utf8.reduce(14695981039346656037) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }

    public static func offset(_ uri: String) -> Float { Float(hash(uri) % 4096) }
}
