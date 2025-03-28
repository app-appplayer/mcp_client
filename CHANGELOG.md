## 0.1.2

* New Features
    * Protocol Update: Full support for all features of the 2024-11-05 protocol specification
    * Progress Tracking: Added onProgress method to receive notifications about progress of long-running operations
    * Operation Cancellation: Added cancelOperation method to cancel running operations
    * Server Health Check: Added healthCheck method to check server's health status
    * Resource Template Enhancement: Added getResourceWithTemplate method to access resources using URI templates
    * Tool Execution with Progress Tracking: Added callToolWithTracking method that returns operation IDs
    * Enhanced Resource Update Notifications: Added onResourceContentUpdated method that includes content information
    * Sampling Response Handling: Added onSamplingResponse method to process sampling results
* New Model Classes
    * ServerHealth: Class to hold server health status information
    * PendingOperation: Class for managing ongoing operations
    * ProgressUpdate: Class for operation progress updates
    * CachedResource: Class for resource caching
    * ToolCallTracking: Class to return tool call results and operation IDs together
* Technical Improvements
    * Enhanced protocol version validation
    * Improved error handling and exception messages
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