//
//  ChatGPTService.swift
//  ChatGPT_ML_Works
//
//  Created by Dariy Kordiyak on 20.06.2023.
//

import Foundation
import GPTEncoder

protocol ChatGPTService: Actor {
    /// The server will stream chunks of data until complete, the method AsyncThrowingStream which can loop using For-Loop
    func sendMessageStream(text: String) async throws -> AsyncThrowingStream<String, Error>
    /// A normal HTTP request and response lifecycle. Server will send the complete text (it will take more time to response)
    func sendMessage(text: String) async throws -> String
}

/// The client stores the history list of the conversation that will be included in the new prompt so ChatGPT aware of the previous context of conversation.
/// When sending new prompt, the client will make sure the token count is not exceeding 4096 using GPTEncoder library to calculate tokens in string,
/// In case it exceeded the token, some of previous conversations will be truncated.
/// In future there's a need to provide an API to specify the token threshold as new gpt-4 model accept much bigger 8k tokens in a prompt.
protocol ChatGPTHistoryHandling: Actor {
    func deleteHistoryList()
    func replaceHistoryList(with messages: [Message])
}

actor ChatGPTAPI {
        
    // MARK: - Properties
    private let urlString = "https://api.openai.com/v1/chat/completions"
    private let apiKey: String
    private let gptEncoder = GPTEncoder()
    private(set) var historyList = [Message]()
    private var model: String {
        return "gpt-3.5-turbo"
    }
    private var systemText: String {
        return "You're a helpful assistant"
    }
    private var temperature: Double {
        /// Typically, a default temperature setting for ChatGPT should be around 0.7
        /// This value allows for a balance between generating creative responses and maintaining a certain level of consistency and relevance
        return 0.7
    }

    private let urlSession = URLSession.shared
    private var urlRequest: URLRequest {
        let url = URL(string: urlString)!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        headers.forEach {  urlRequest.setValue($1, forHTTPHeaderField: $0) }
        return urlRequest
    }
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "YYYY-MM-dd"
        return df
    }()
    private let jsonDecoder: JSONDecoder = {
        let jsonDecoder = JSONDecoder()
        jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
        return jsonDecoder
    }()
    private var headers: [String: String] {
        [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(apiKey)"
        ]
    }
    
    // MARK: - Initialization
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    // MARK: - Private
    private func jsonBody(text: String, model: String, systemText: String, temperature: Double, stream: Bool = true) throws -> Data {
        
        func generateMessages(from text: String, systemText: String) -> [Message] {
            var messages = [systemMessage(content: systemText)] + historyList + [Message(role: "user", content: text)]
            if gptEncoder.encode(text: messages.content).count > 4096  {
                _ = historyList.removeFirst()
                messages = generateMessages(from: text, systemText: systemText)
            }
            return messages
        }
        
        let request = Request(model: model,
                        temperature: temperature,
                        messages: generateMessages(from: text, systemText: systemText),
                        stream: stream)
        return try JSONEncoder().encode(request)
    }
    
    private func systemMessage(content: String) -> Message {
        .init(role: "system", content: content)
    }
    
    private func appendToHistoryList(userText: String, responseText: String) {
        historyList.append(Message(role: "user", content: userText))
        historyList.append(Message(role: "assistant", content: responseText))
    }
}

extension ChatGPTAPI: ChatGPTService {
    
    func sendMessageStream(text: String) async throws -> AsyncThrowingStream<String, Error> {
        var urlRequest = self.urlRequest
        urlRequest.httpBody = try jsonBody(text: text, model: model, systemText: systemText, temperature: temperature)
        let (result, response) = try await urlSession.bytes(for: urlRequest)
        try Task.checkCancellation()
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GPTError.invalidResponse
        }
        
        guard 200...299 ~= httpResponse.statusCode else {
            var errorText = ""
            for try await line in result.lines {
                try Task.checkCancellation()
                errorText += line
            }
            if let data = errorText.data(using: .utf8), let errorResponse = try? jsonDecoder.decode(ErrorRootResponse.self, from: data).error {
                errorText = "\n\(errorResponse.message)"
            }
            throw GPTError.badResponse("\(httpResponse.statusCode). \(errorText)")
        }
        
        
        var responseText = ""
        return AsyncThrowingStream { [weak self] in
            guard let self else { fatalError("") }
            for try await line in result.lines {
                try Task.checkCancellation()
                if line.hasPrefix("data: "),
                   let data = line.dropFirst(6).data(using: .utf8),
                   let response = try? self.jsonDecoder.decode(StreamCompletionResponse.self, from: data),
                   let text = response.choices.first?.delta.content {
                    responseText += text
                    return text
                }
            }
            await self.appendToHistoryList(userText: text, responseText: responseText)
            return nil
        }
    }

    func sendMessage(text: String) async throws -> String {
        var urlRequest = self.urlRequest
        urlRequest.httpBody = try jsonBody(text: text, model: model, systemText: systemText, temperature: temperature, stream: false)
        
        let (data, response) = try await urlSession.data(for: urlRequest)
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GPTError.invalidResponse
        }
        
        guard 200...299 ~= httpResponse.statusCode else {
            var error = GPTError.badResponse("\(httpResponse.statusCode)")
            throw error
        }
        
        do {
            let completionResponse = try self.jsonDecoder.decode(CompletionResponse.self, from: data)
            let responseText = completionResponse.choices.first?.message.content ?? ""
            self.appendToHistoryList(userText: text, responseText: responseText)
            return responseText
        } catch {
            throw error
        }
    }
}

extension ChatGPTAPI: ChatGPTHistoryHandling {
    
    func deleteHistoryList() {
        historyList.removeAll()
    }
        
    func replaceHistoryList(with messages: [Message]) {
        historyList = messages
    }
}
