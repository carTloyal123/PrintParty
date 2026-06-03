//
//  PrinterStore.swift
//  printparty-gateway
//
//  Simple file-based persistence for registered printers so they survive
//  gateway restarts. Stores as JSON at ~/.printparty/printers.json.
//
//  This replaces the need for `./register-printer.sh` after every restart.
//
//  IMPORTANT: This struct must only be called from the PrinterService actor
//  context to avoid concurrent file I/O. (H-14)
//

import Foundation
import Logging

struct PrinterStore {

    private let filePath: String
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
        // Store in ~/.printparty/ by default; override with PRINTPARTY_DATA_DIR env.
        let dataDir = ProcessInfo.processInfo.environment["PRINTPARTY_DATA_DIR"]
            ?? (NSHomeDirectory() + "/.printparty")
        self.filePath = dataDir + "/printers.json"

        // Ensure directory exists
        try? FileManager.default.createDirectory(
            atPath: dataDir,
            withIntermediateDirectories: true
        )
    }

    func load() -> [PrinterService.PrinterConfig] {
        guard FileManager.default.fileExists(atPath: filePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let configs = try? JSONDecoder().decode([PrinterService.PrinterConfig].self, from: data) else {
            logger.info("No saved printers found at \(filePath)")
            return []
        }
        logger.info("Loaded \(configs.count) printer(s) from \(filePath)")
        return configs
    }

    func save(_ configs: [PrinterService.PrinterConfig]) {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
            // H-21: Restrict file permissions to owner-only since it contains access codes.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: filePath
            )
            logger.info("Saved \(configs.count) printer(s) to \(filePath)")
        } catch {
            logger.error("Failed to save printers: \(error)")
        }
    }
}
