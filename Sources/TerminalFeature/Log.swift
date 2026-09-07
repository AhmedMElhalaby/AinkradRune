import os

/// This repo's `os.Logger` categories, all under the shared Ainkrad
/// subsystem so a user's whole install filters as one stream in Console.app.
///
/// The subsystem is spelled out here rather than taken from the SDK's
/// `AinkradLog` because this repo's AinkradAppKit pin (6cd1599) predates
/// that type. Switch to `AinkradLog.logger(app:area:)` whenever this pin
/// next moves forward.
enum Log {
    private static let subsystem = "com.ainkrad.app"
    static let terminal = Logger(subsystem: subsystem, category: "rune.terminal")
    static let process = Logger(subsystem: subsystem, category: "rune.process")
    static let session = Logger(subsystem: subsystem, category: "rune.session")
}
