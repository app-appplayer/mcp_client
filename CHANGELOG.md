## 0.1.2

* Logging System Improvement
    * Enhanced the default logger to allow dynamic log level configuration
    * Reduced redundant log statements and improved performance for higher-volume logging
    * Added options to colorize logs and include timestamps for easier debugging

## 0.1.1

* Bug fixes

## 0.1.0

* Initial release
* Created Model Context Protocol (MCP) client implementation for Dart
* Features:
    * Connect to MCP servers with standardized protocol support
    * Access data through Resources
    * Execute functionality through Tools
    * Utilize interaction patterns through Prompts
    * Support for Roots management
    * Support for Sampling (LLM text generation)
        * Multiple transport layers:
        * Standard I/O for local process communication
    * Server-Sent Events (SSE) for HTTP-based communication
    * Platform support: Android, iOS, web, Linux, Windows, macOS