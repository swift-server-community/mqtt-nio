//===----------------------------------------------------------------------===//
//
// This source file is part of the MQTTNIO project
//
// Copyright (c) 2020-2026 Adam Fowler
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging

extension Logger {
    func withLogLevel(_ logLevel: Logger.Level) -> Logger {
        var logger = self
        logger.logLevel = logLevel
        return logger
    }
}
