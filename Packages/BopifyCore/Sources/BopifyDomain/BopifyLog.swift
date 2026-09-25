import os

/// One subsystem for the whole app, one category per component, so
/// `log stream --subsystem my.snsoft.bopify` shows everything and
/// `--category auth` narrows it.
public enum BopifyLog {
    public static let subsystem = "my.snsoft.bopify"

    public static let auth = Logger(subsystem: subsystem, category: "auth")
    public static let keychain = Logger(subsystem: subsystem, category: "keychain")
    public static let callback = Logger(subsystem: subsystem, category: "callback")
    public static let library = Logger(subsystem: subsystem, category: "library")
    public static let playback = Logger(subsystem: subsystem, category: "playback")
}
