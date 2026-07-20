//
// This source file is part of the MQTTNIO project
// Copyright (c) 2020-2026 the MQTTNIO authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

import Logging
import Testing

extension Logger {
    func withLogLevel(_ logLevel: Logger.Level) -> Logger {
        var logger = self
        logger.logLevel = logLevel
        return logger
    }
}

struct DefaultLoggerTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        try await withLogger(Logger(label: test.displayName ?? test.name).withLogLevel(.trace)) { _ in
            try await function()
        }
    }
}

extension Trait where Self == DefaultLoggerTrait {
    /// A trait that provides a default task-local `Logger` for all tests and suites.
    ///
    /// The logger is configured with a log level of `trace` and a label that corresponds to the test display name.
    static var defaultLogger: Self { Self() }
}
