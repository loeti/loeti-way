import Foundation

/// Terminal interaction. Prompts go to stderr, so stdout stays clean for piping.
enum Console {
    static func error(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func prompt(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    static func confirm(_ question: String) -> Bool {
        prompt("\(question) [j/N] ")
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return ["j", "ja", "y", "yes"].contains(answer)
    }

    /// Reads a line without echo. Without a terminal (e.g. `pbpaste | lw github`) it reads stdin.
    static func readSecret(_ text: String) -> String? {
        guard isatty(STDIN_FILENO) != 0 else {
            return readLine(strippingNewline: true)
        }
        prompt(text)
        var original = termios()
        tcgetattr(STDIN_FILENO, &original)
        var silent = original
        silent.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &silent)
        defer {
            tcsetattr(STDIN_FILENO, TCSANOW, &original)
            prompt("\n")
        }
        return readLine(strippingNewline: true)
    }

    /// Opens a URL in the browser; false if that didn't work.
    static func open(_ url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        #if os(macOS)
        process.arguments = ["open", url.absoluteString]
        #else
        process.arguments = ["xdg-open", url.absoluteString]
        #endif
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
