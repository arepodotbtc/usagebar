import AppKit
import Darwin
import UsageBarCore

if CommandLine.arguments.contains("--self-test") {
    do {
        try ParserSelfTest.run()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("self-test failed: \(error)\n".utf8))
        exit(1)
    }
}

if CommandLine.arguments.contains("--probe") {
    let semaphore = DispatchSemaphore(value: 0)
    var code: Int32 = 1
    Task.detached {
        defer { semaphore.signal() }
        let snapshot = await UsageAggregator.fetchAll()
        do {
            let data = try UsageAggregator.probeJSON(snapshot)
            if let text = String(data: data, encoding: .utf8) {
                FileHandle.standardOutput.write(Data(text.utf8))
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            code = snapshot.providers.contains(where: { $0.error != nil }) ? 2 : 0
        } catch {
            FileHandle.standardError.write(Data("probe encode failed: \(error)\n".utf8))
            code = 1
        }
    }
    _ = semaphore.wait(timeout: .now() + 40)
    exit(code)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
withExtendedLifetime(delegate) {
    app.run()
}
