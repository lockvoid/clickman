import ClickMan
import Foundation

/// A Swift client for the E2E suite, through the public API only:
/// `ClickManE2EWorker <endpoint> <write-key> <store-path>` opens ClickMan on the
/// store, prints one ready line, then answers every JSON command line on stdin
/// with one JSON line on stdout until stdin ends. Diagnostics go to stderr.
@main
@MainActor
enum Worker {
    static func main() async {
        let clickMan = open(CommandLine.arguments)
        emit(["ready": true, "language": "swift"])
        while let line = readLine() {
            guard !line.allSatisfy(\.isWhitespace) else {
                continue
            }
            await answer(line, clickMan: clickMan)
        }
    }

    private static func open(_ arguments: [String]) -> ClickMan {
        guard arguments.count == 4, let endpoint = URL(string: arguments[1]) else {
            fail("usage: ClickManE2EWorker <endpoint> <write-key> <store-path>")
        }
        var configuration = ClickMan.Configuration(endpoint: endpoint, writeKey: arguments[2])
        configuration.storage = URL(fileURLWithPath: arguments[3])
        do {
            return try ClickMan(configuration: configuration)
        } catch {
            fail("ClickMan could not open \(arguments[3]): \(error)")
        }
    }

    private static func answer(_ line: String, clickMan: ClickMan) async {
        let command: Command
        do {
            command = try Command(line)
        } catch {
            return emit(["ok": false, "error": String(describing: error)])
        }
        await perform(command, on: clickMan)
    }

    private static func perform(_ command: Command, on clickMan: ClickMan) async {
        switch command {
        case .identify(let externalId):
            clickMan.identify(externalId)
        case .traits(let traits):
            clickMan.setTraits(traits.mapValues { Optional($0) })
        case .track(let event, let properties):
            clickMan.track(event, properties: properties)
        case .reset:
            clickMan.reset()
        case .flush:
            await clickMan.flush()
            return emit(["ok": true, "pending": clickMan.pendingEvents])
        case .pending:
            return emit(["ok": true, "pending": clickMan.pendingEvents])
        }
        emit(["ok": true])
    }

    /// Writes one line, its keys in the order given.
    private static func emit(_ fields: KeyValuePairs<String, Any>) {
        do {
            let members = try fields.map { key, value in "\(try fragment(key)):\(try fragment(value))" }
            FileHandle.standardOutput.write(Data("{\(members.joined(separator: ","))}\n".utf8))
        } catch {
            fail("could not write an answer: \(error)")
        }
    }

    private static func fragment(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }
}
