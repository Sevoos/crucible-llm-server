import Foundation
import Network

/// Minimal HTTP server that serves an OpenAI-compatible chat completions API
class HTTPServer {
    private var listener: NWListener?
    private let port: UInt16
    private weak var llamaState: LlamaState?

    var isRunning: Bool { listener != nil }

    init(port: UInt16 = 8080) {
        self.port = port
    }

    func start(llamaState: LlamaState) throws {
        self.llamaState = llamaState
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener?.start(queue: .global(qos: .userInitiated))
        print("HTTP Server started on port \(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        print("HTTP Server stopped")
    }

    func getLocalIP() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { continue }
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" || name == "en1" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                    &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                        address = String(cString: hostname)
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(connection, reader: HTTPRequestReader())
    }

    private func receiveRequest(_ connection: NWConnection, reader: HTTPRequestReader) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            do {
                if let request = try reader.append(data ?? Data(), isComplete: isComplete) {
                    self.routeRequest(request, connection: connection)
                } else {
                    self.receiveRequest(connection, reader: reader)
                }
            } catch let failure as HTTPFailure {
                self.sendError(connection, status: failure.status, message: failure.message)
            } catch {
                self.sendError(connection, status: "400 Bad Request", message: "Could not read HTTP request.")
            }
        }
    }

    private func routeRequest(_ request: HTTPRequest, connection: NWConnection) {
        // CORS headers for all responses
        if request.method == "OPTIONS" {
            sendResponse(connection: connection, status: "200 OK", body: "", extraHeaders: [
                "Access-Control-Allow-Origin: *",
                "Access-Control-Allow-Methods: GET, POST, OPTIONS",
                "Access-Control-Allow-Headers: Content-Type, Authorization"
            ])
            return
        }

        switch request.path {
        case "/":
            sendResponse(connection: connection, status: "200 OK", body: "Crucible LLM Server is running")
        case "/v1/models", "/api/tags":
            handleModels(connection: connection)
        case "/v1/chat/completions":
            if request.method == "POST" {
                handleChatCompletion(body: request.body, connection: connection)
            } else {
                sendError(connection, status: "405 Method Not Allowed", message: "Use POST for chat completions.")
            }
        default:
            sendError(connection, status: "404 Not Found", message: "Endpoint not found.")
        }
    }

    private func handleModels(connection: NWConnection) {
        let response = """
        {"object":"list","data":[{"id":"local","object":"model","created":0,"owned_by":"local"}]}
        """
        sendResponse(connection: connection, status: "200 OK", body: response, contentType: "application/json")
    }

    private func handleChatCompletion(body: Data, connection: NWConnection) {
        let request: ChatCompletionRequest
        do {
            request = try JSONDecoder().decode(ChatCompletionRequest.self, from: body)
        } catch let failure as HTTPFailure {
            sendError(connection, status: failure.status, message: failure.message)
            return
        } catch {
            sendError(connection, status: "400 Bad Request", message: "Expected a JSON chat request with a messages array.")
            return
        }

        Task {
            guard let llamaState = self.llamaState else {
                self.sendError(connection, status: "503 Service Unavailable", message: "No model loaded.")
                return
            }

            let messages = request.messages.map { ChatMessage(role: $0.role, content: $0.content) }
            do {
                let result = try await llamaState.completeForAPI(messages: messages, maxTokens: request.maxTokens)
                let response = try ChatCompletionResponse(text: result.text, finishReason: result.finishReason).encode(stream: request.stream)
                self.sendResponse(connection: connection, status: "200 OK", body: response.body, contentType: response.contentType)
            } catch let error as LlamaError {
                let status: String
                switch error {
                case .noModelLoaded: status = "503 Service Unavailable"
                case .invalidPrompt, .promptTooLong: status = "400 Bad Request"
                default: status = "500 Internal Server Error"
                }
                self.sendError(connection, status: status, message: error.localizedDescription)
            } catch {
                self.sendError(connection, status: "500 Internal Server Error", message: "Failed to encode the chat response.")
            }
        }
    }

    private func sendError(_ connection: NWConnection, status: String, message: String) {
        let type = status.hasPrefix("5") ? "server_error" : "invalid_request_error"
        let body = (try? encodeJSON(["error": ["message": message, "type": type]])) ?? "{}"
        sendResponse(connection: connection, status: status, body: body, contentType: "application/json")
    }

    private func sendResponse(connection: NWConnection, status: String, body: String,
                              contentType: String = "text/plain", extraHeaders: [String] = []) {
        var headers = "HTTP/1.1 \(status)\r\n"
        headers += "Content-Type: \(contentType)\r\n"
        headers += "Content-Length: \(body.utf8.count)\r\n"
        headers += "Access-Control-Allow-Origin: *\r\n"
        headers += "Connection: close\r\n"
        for header in extraHeaders {
            headers += "\(header)\r\n"
        }
        headers += "\r\n"

        let responseData = (headers + body).data(using: .utf8)!
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
