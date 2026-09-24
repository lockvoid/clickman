import ClickMan
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4, let endpoint = URL(string: arguments[1]) else {
    FileHandle.standardError.write(Data("usage: clickman-e2e-client <endpoint> <write key> <queue file>\n".utf8))
    exit(2)
}

var configuration = ClickMan.Configuration(endpoint: endpoint, writeKey: arguments[2])
configuration.storage = URL(fileURLWithPath: arguments[3])
let analytics = try ClickMan(configuration: configuration)

analytics.identify("e2e-swift")
analytics.setTraits(["plan": "pro"])
analytics.track("export_completed", properties: ["format": "mp4", "contact": ["email": "someone@example.com"]])
await analytics.flush()

guard analytics.pendingEvents == 0 else {
    FileHandle.standardError.write(Data("\(analytics.pendingEvents) events were not accepted\n".utf8))
    exit(1)
}
