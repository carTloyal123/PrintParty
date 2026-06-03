//
//  PrintPartyGatewayApp.swift
//  printparty-gateway
//
//  Entry point. Boots Vapor, wires up routes, prints the initial pairing
//  code to the terminal so the user can paste it into the iOS app.
//  Vapor handles SIGINT/SIGTERM internally via app.execute().
//

import Vapor

@main
struct PrintPartyGatewayApp {
    static func main() async {
        do {
            var env = try Environment.detect()
            try LoggingSystem.bootstrap(from: &env)
            let app = try await Application.make(env)
            do {
                try await configure(app)
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

        // Port already in use
        if message.contains("Address already in use") || message.contains("EADDRINUSE") {
            print("""

            ╔═══════════════════════════════════════════════════════════════╗
               ERROR: Port is already in use.

               Another process is listening on the same port.
               This usually means another gateway instance is running.

               Fix: stop the other process, or set a different port:
                 export PORT=8081
                 ./start-gateway.sh
            ╚═══════════════════════════════════════════════════════════════╝
            """)
        }
        // Permission denied (e.g. port < 1024)
        else if message.contains("Permission denied") || message.contains("EACCES") {
            print("""

            ╔═══════════════════════════════════════════════════════════════╗
               ERROR: Permission denied.

               Cannot bind to the requested port (ports below 1024
               require root/sudo). Use a higher port:
                 export PORT=8080
                 ./start-gateway.sh
            ╚═══════════════════════════════════════════════════════════════╝
            """)
        }
        // Connection refused (e.g. relay not running)
        else if message.contains("Connection refused") {
            print("""

            ╔═══════════════════════════════════════════════════════════════╗
               ERROR: Connection refused.

               Could not connect to the relay or a required service.
               Make sure the relay is running first:
                 ./start-relay.sh
            ╚═══════════════════════════════════════════════════════════════╝
            """)
        }
        // Generic fallback
        else {
            print("""

            ╔═══════════════════════════════════════════════════════════════╗
               ERROR: Gateway failed to start.

               \(message)

               For help, check the logs above or visit:
               https://github.com/printparty/printparty
            ╚═══════════════════════════════════════════════════════════════╝
            """)
        }
    }
}
