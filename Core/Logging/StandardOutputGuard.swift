import Foundation

/// Keeps writes to stdout and stderr from blocking the app.
///
/// When the app is started from a PC, both streams are a terminal owned by the launching tool.
/// Once nothing reads that terminal any more, a write to it blocks forever. llama.cpp and
/// LiteRT-LM write thousands of lines while they load a model, so a model load hung.
/// Output now goes through a pipe that a thread drains: it is passed on while the original
/// stream accepts it and dropped otherwise.
enum StandardOutputGuard {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        // A pipe makes stdout fully buffered; keep it line buffered as on a terminal.
        setvbuf(stdout, nil, _IOLBF, 0)
        for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
            let original = dup(descriptor)
            var ends: [Int32] = [0, 0]
            guard original >= 0, pipe(&ends) == 0 else { continue }
            dup2(ends[1], descriptor)
            close(ends[1])
            _ = fcntl(original, F_SETFL, fcntl(original, F_GETFL) | O_NONBLOCK)
            let source = ends[0]
            Thread.detachNewThread { pump(from: source, to: original) }
        }
    }

    private static func pump(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var stalled = false
        while true {
            let count = read(source, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            var offset = 0
            while offset < count {
                // Give a reader a moment to catch up; once it has stopped reading, drop the
                // output without waiting until it reads again.
                var state = pollfd(fd: destination, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&state, 1, stalled ? 0 : 200) > 0 && state.revents & Int16(POLLOUT) != 0
                stalled = !ready
                guard ready else { break }
                let written = buffer.withUnsafeBytes { write(destination, $0.baseAddress! + offset, count - offset) }
                guard written > 0 else { break }
                offset += written
            }
        }
    }
}
