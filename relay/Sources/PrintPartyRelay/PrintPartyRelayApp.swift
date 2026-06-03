//
//  PrintPartyRelayApp.swift
//  printparty-relay
//
//  The relay is a stateless APNs forwarder. It holds the .p8 key and
//  forwards encrypted Live Activity payloads from self-hosted gateways
//  to Apple's APNs servers. It never sees plaintext print data.
//  Vapor handles SIGINT/SIGTERM internally via app.execute().
//

import Vapor

@main
struct PrintPartyRelayApp {
    static func main() async {
        do {
            var env = try Environment.detect()
            try LoggingSystem.bootstrap(from: &env)
            let app = try await Application.make(env)
            do {
                try await configurerelay(app)
            } catch {
                app.logger.report(error: error)
                try? await app.asyncShutdown()
                printFriendlyError(error)
                Foundation.exit(1)
            }
            try await app.execute()
        } catch {
            printFriendlyError(error)
            Foundation.exit(1)
        }
    }

    private static func printFriendlyError(_ error: Error) {
        let message = "\(error)"

        if message.contains("Address already in use") || message.contains("EADDRINUSE") {
            print("""

            ╔═══════════════════════════════════════════════════════════════╗
               ERROR: Port is already in use.

               Another process is listening on the same port.
               This usually means another relay instance is running.

               Fix: stop the other process, or set a different port:
                 export PORT=8091
                 ./start-relay.sh
            ╚═══════════════════════════════════════════════════════════════╝
            """)
        }
        else if message.contains("Permission denied") || message.contains("EACCES") {
            print("""

            ╔═══════════════════════════════════════════════════════════════╗
               ERROR: Permission denied.

               Cannot bind to the requested port (ports below 1024
               require root/sudo). Use a higher port:
                 export PORT=8090
                 ./start-relay.sh
            ╚═══════════════════════════════════════════════════════════════╝
            """)
        }
        else if message.contains("No such file") && message.contains(".p8") {
            print("""

            ╔═══════════════════════════════════════════════════════════════╗
               ERROR: APNs key file not found.

               The .p8 key file could not be found at the path specified
               by APNS_KEY_PATH. Check that the file exists:
                 ls -la $APNS_KEY_PATH

               Get a key from Apple Developer portal:
                 https://developer.apple.com/account/resources/authkeys
            ╚═══════════════════════════════════════════════════════════════╝
            """)
        }
        else {
            print("""

            ╔═══════════════════════════════════════════════════════════════╗
               ERROR: Relay failed to start.

               \(message)

               For help, check the logs above or visit:
               https://github.com/printparty/printparty
            ╚═══════════════════════════════════════════════════════════════╝
            """)
        }
    }
}
