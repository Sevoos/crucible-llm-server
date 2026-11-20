import Foundation

struct HTTPFailure: Error {
    let status: String
    let message: String
}

struct HTTPRequest {
    let method: String
    let path: String
    let body: Data
}

final class HTTPRequestReader {
    private static let headerLimit = 16 * 1024
    private static let bodyLimit = 1024 * 1024
    private static let headerEnd = Data("\r\n\r\n".utf8)

    private var buffer = Data()
    private var head: (method: String, path: String, length: Int)?

    func append(_ data: Data, isComplete: Bool) throws -> HTTPRequest? {
        buffer.append(data)
        if head == nil {
            guard let end = buffer.range(of: Self.headerEnd) else {
                if buffer.count > Self.headerLimit { throw Self.headersTooLarge }
                if isComplete { throw Self.incomplete }
                return nil
            }
            guard end.upperBound <= Self.headerLimit else { throw Self.headersTooLarge }
            head = try Self.parseHead(buffer[..<end.lowerBound])
            buffer.removeSubrange(..<end.upperBound)
        }

        guard let head, buffer.count >= head.length else {
            if isComplete { throw Self.incomplete }
            return nil
        }
        return HTTPRequest(method: head.method, path: head.path, body: Data(buffer.prefix(head.length)))
    }

    private static func parseHead(_ bytes: Data) throws -> (String, String, Int) {
        let malformed = HTTPFailure(status: "400 Bad Request", message: "Invalid HTTP request headers.")
        let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { throw malformed }

        var length: Int?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw malformed }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "content-length":
                guard length == nil, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else {
                    throw malformed
                }
                guard let count = Int(value), count <= bodyLimit else {
                    throw HTTPFailure(status: "413 Content Too Large", message: "Request body exceeds 1 MiB.")
                }
                length = count
            case "transfer-encoding":
                throw HTTPFailure(status: "501 Not Implemented", message: "Send the request with Content-Length.")
            case "content-encoding" where value.lowercased() != "identity":
                throw HTTPFailure(status: "415 Unsupported Media Type", message: "Send uncompressed JSON.")
            case "expect":
                throw HTTPFailure(status: "417 Expectation Failed", message: "Send the request without an Expect header.")
            default:
                break
            }
        }
        let method = String(requestLine[0])
        if method == "POST", length == nil {
            throw HTTPFailure(status: "411 Length Required", message: "Send the request with Content-Length.")
        }
        return (method, String(requestLine[1]), length ?? 0)
    }

    private static let incomplete = HTTPFailure(status: "400 Bad Request", message: "Incomplete HTTP request.")
    private static let headersTooLarge = HTTPFailure(status: "431 Request Header Fields Too Large", message: "Request headers exceed 16 KiB.")
}

struct ChatCompletionRequest: Decodable {
    struct Message: Decodable {
        let role: String
        let content: String

        private enum CodingKeys: String, CodingKey { case role, content }
        private struct Part: Decodable {
            let type: String
            let text: String?
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            role = try fields.decode(String.self, forKey: .role)
            guard ["system", "developer", "user", "assistant"].contains(role) else {
                throw HTTPFailure(status: "400 Bad Request", message: "Unsupported message role: \(role).")
            }
            if let text = try? fields.decode(String.self, forKey: .content) {
                content = text
            } else {
                let parts = try fields.decode([Part].self, forKey: .content)
                guard parts.allSatisfy({ $0.type == "text" && $0.text != nil }) else {
                    throw HTTPFailure(status: "400 Bad Request", message: "Only text message content is supported.")
                }
                content = parts.compactMap(\.text).joined()
            }
        }
    }

    let messages: [Message]
    let maxTokens: Int
    let stream: Bool

    private enum CodingKeys: String, CodingKey {
        case messages, stream, tools
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        messages = try fields.decode([Message].self, forKey: .messages)
        guard !messages.isEmpty else {
            throw HTTPFailure(status: "400 Bad Request", message: "Provide at least one message.")
        }
        maxTokens = try fields.decodeIfPresent(Int.self, forKey: .maxCompletionTokens)
            ?? fields.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 500
        guard maxTokens > 0 else {
            throw HTTPFailure(status: "400 Bad Request", message: "The output token limit must be positive.")
        }
        stream = try fields.decodeIfPresent(Bool.self, forKey: .stream) ?? false
        if fields.contains(.tools), try !fields.decodeNil(forKey: .tools),
           try !fields.nestedUnkeyedContainer(forKey: .tools).isAtEnd {
            throw HTTPFailure(status: "400 Bad Request", message: "Tool calling is not supported. Disable tools for this model in the client.")
        }
    }
}

struct ChatCompletionResponse {
    let text: String
    let finishReason: String
    let id = "chatcmpl-\(UUID().uuidString)"
    let created = Int(Date().timeIntervalSince1970)

    func encode(stream: Bool) throws -> (body: String, contentType: String) {
        if stream {
            let content = try chunk(["role": "assistant", "content": text], finish: NSNull())
            let finish = try chunk([:], finish: finishReason)
            return ("data: \(content)\n\ndata: \(finish)\n\ndata: [DONE]\n\n", "text/event-stream")
        }

        let choice: [String: Any] = [
            "index": 0, "finish_reason": finishReason,
            "message": ["role": "assistant", "content": text]
        ]
        return (try encodeJSON(envelope(object: "chat.completion", choice: choice)), "application/json")
    }

    private func chunk(_ delta: [String: String], finish: Any) throws -> String {
        try encodeJSON(envelope(object: "chat.completion.chunk", choice: ["index": 0, "delta": delta, "finish_reason": finish]))
    }

    private func envelope(object: String, choice: [String: Any]) -> [String: Any] {
        ["id": id, "object": object, "created": created, "model": "local", "choices": [choice]]
    }
}

func encodeJSON(_ value: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
}
