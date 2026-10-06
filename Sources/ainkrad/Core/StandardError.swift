import Foundation

/// Writes one line to stderr. Errors go here so a script reading an
/// `ainkrad` command's stdout only ever sees its results.
func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
