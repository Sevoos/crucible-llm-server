import Foundation

@main
struct HTTPProtocolTests {
    static func main() throws {
        try testFragmentedRequest()
        try testIncompleteRequest()
        try testHeaderOnlyRequest()
        try testChatFields()
        try testChatResponse()
        print("HTTP protocol tests passed")
    }

    static func testFragmentedRequest() throws {
        let text = String(repeating: "a", count: 70_000) + "🙂"
        let body = Data(#"{"messages":[{"role":"user","content":"\#(text)"}],"stream":true}"#.utf8)
        let head = "POST /v1/chat/completions HTTP/1.1\r\ncontent-length: \(body.count)\r\n\r\n"
        let reader = HTTPRequestReader()

        let headerFragment = try reader.append(Data(head.utf8.dropLast()), isComplete: false)
        precondition(headerFragment == nil)
        // Split both the header terminator and the multibyte emoji across reads.
        let firstChunkSize = 64 * 1024 - 1
        let firstBodyChunk = try reader.append(Data(head.utf8.suffix(1)) + body.prefix(firstChunkSize), isComplete: false)
        precondition(firstBodyChunk == nil)
        let emojiStart = body.range(of: Data("🙂".utf8))!.lowerBound
        let split = emojiStart + 1
        let secondBodyChunk = try reader.append(body[firstChunkSize..<split], isComplete: false)
        precondition(secondBodyChunk == nil)
        let request = try reader.append(body[split...], isComplete: false)
        precondition(request?.path == "/v1/chat/completions" && request?.body == body)
        let chat = try JSONDecoder().decode(ChatCompletionRequest.self, from: request!.body)
        precondition(chat.stream && chat.messages[0].content == text)
    }

    static func testIncompleteRequest() throws {
        let truncated = Data("POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 20\r\n\r\n{}".utf8)
        do {
            _ = try HTTPRequestReader().append(truncated, isComplete: true)
            preconditionFailure("Expected a truncated-body error")
        } catch let failure as HTTPFailure {
            precondition(failure.message == "Incomplete HTTP request.")
        }

        let overLimit = Data("POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n".utf8)
        do {
            _ = try HTTPRequestReader().append(overLimit, isComplete: false)
            preconditionFailure("Expected an oversized-body error")
        } catch let failure as HTTPFailure {
            precondition(failure.status.hasPrefix("413"))
        }
    }

    static func testHeaderOnlyRequest() throws {
        let request = try HTTPRequestReader().append(Data("GET /v1/models HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8), isComplete: false)
        precondition(request?.method == "GET" && request?.path == "/v1/models" && request?.body.isEmpty == true)
    }

    static func testChatFields() throws {
        let body = Data(#"{"messages":[{"role":"user","content":[{"type":"text","text":"Hi "},{"type":"text","text":"there"}]}],"max_tokens":20,"max_completion_tokens":10,"tools":[]}"#.utf8)
        let request = try JSONDecoder().decode(ChatCompletionRequest.self, from: body)
        precondition(!request.stream && request.maxTokens == 10 && request.messages[0].content == "Hi there")

        let withTools = Data(#"{"messages":[{"role":"user","content":"Hi"}],"tools":[{"type":"function"}]}"#.utf8)
        do {
            _ = try JSONDecoder().decode(ChatCompletionRequest.self, from: withTools)
            preconditionFailure("Expected a tool-calling error")
        } catch let failure as HTTPFailure {
            precondition(failure.message.hasPrefix("Tool calling is not supported."))
        }
    }

    static func testChatResponse() throws {
        let response = ChatCompletionResponse(text: "Hi\n🙂", finishReason: "length")
        let streamed = try response.encode(stream: true)
        precondition(streamed.contentType == "text/event-stream")
        let events = streamed.body.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        precondition(events.count == 3 && events[2] == "data: [DONE]")
        let first = try choice(String(events[0].dropFirst("data: ".count)))
        let last = try choice(String(events[1].dropFirst("data: ".count)))
        precondition((first["delta"] as? [String: String])?["content"] == response.text)
        precondition(last["finish_reason"] as? String == "length")

        let plain = try response.encode(stream: false)
        precondition(plain.contentType == "application/json")
        let message = try choice(plain.body)["message"] as? [String: String]
        precondition(message?["content"] == response.text)
    }

    static func choice(_ json: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return (object["choices"] as! [[String: Any]])[0]
    }
}
