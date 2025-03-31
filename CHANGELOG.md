## 0.1.4

* Bug Fixes

## 0.1.3

* Fixed
    * SSE Transport Connection Issues: Fixed critical issue with Server-Sent Events (SSE) connection where the client could not properly process JSON-RPC responses from the server.
      * Improved event stream processing to correctly parse JSON-RPC messages
      * Fixed handling of the endpoint event to establish the message channel
      * Enhanced buffer management for fragmented SSE event data
    * JSON-RPC Message Flow: Corrected the bidirectional communication flow between client and server:
      * Client requests via HTTP POST to message endpoint now properly receive responses
      * Fixed timeout issues by correctly handling asynchronous SSE responses
* Improved
    * Error Handling: Enhanced error reporting and recovery for connection issues
    * Logging: Added more detailed diagnostic logging for easier troubleshooting
    * Stability: More robust message endpoint URL construction and session handling
* Technical Notes
    * Updated SseClientTransport implementation to maintain persistent connections
    * Fixed JSON response type handling for resource templates
    * Improved session management and reconnection logic

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