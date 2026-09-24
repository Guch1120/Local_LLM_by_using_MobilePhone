import Foundation
import Network

private struct HTTPIncomingRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
}

private enum HTTPParseError: Error {
    case badRequest
    case tooLarge
}

private final class HTTPConnectionSession {
    private let connection: NWConnection
    private var buffer = Data()
    var requestHandler: ((HTTPIncomingRequest, HTTPConnectionSession) -> Void)?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.connection.cancel() }
        }
        connection.start(queue: queue)
        receiveNext()
    }

    func sendJSON(_ object: Any, status: Int) async {
        guard let body = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            await sendRaw(status: 500, body: Data("{}".utf8), contentType: "application/json")
            return
        }
        await sendRaw(status: status, body: body, contentType: "application/json; charset=utf-8")
    }

    func beginEventStream() async throws {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache\r\nConnection: close\r\nTransfer-Encoding: chunked\r\nX-Accel-Buffering: no\r\n\r\n"
        try await sendBytes(Data(header.utf8))
    }

    func sendEvent(_ object: Any) async throws {
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var event = Data("data: ".utf8)
        event.append(json)
        event.append(Data("\n\n".utf8))
        try await sendChunk(event)
    }

    func sendDone() async throws {
        try await sendChunk(Data("data: [DONE]\n\n".utf8))
        try await sendBytes(Data("0\r\n\r\n".utf8))
        connection.cancel()
    }

    func sendStreamError(_ object: Any) async {
        do {
            try await sendEvent(object)
            try await sendDone()
        } catch {
            connection.cancel()
        }
    }

    private func sendRaw(status: Int, body: Data, contentType: String) async {
        let reason = Self.reasonPhrase(status)
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        do { try await sendBytes(response) }
        catch { }
        connection.cancel()
    }

    private func sendChunk(_ data: Data) async throws {
        var framed = Data(String(data.count, radix: 16).utf8)
        framed.append(Data("\r\n".utf8))
        framed.append(data)
        framed.append(Data("\r\n".utf8))
        try await sendBytes(framed)
    }

    private func sendBytes(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.connection.cancel()
                _ = error
                return
            }
            if let data { self.buffer.append(data) }
            do {
                if self.buffer.count > 25 * 1024 * 1024 {
                    throw HTTPParseError.tooLarge
                }
                if let request = try Self.parse(&self.buffer) {
                    self.requestHandler?(request, self)
                    return
                }
            } catch HTTPParseError.tooLarge {
                Task { await self.sendJSON(["error": ["type": "invalid_request", "message": "Request body is too large."]], status: 413) }
                return
            } catch {
                Task { await self.sendJSON(["error": ["type": "invalid_request", "message": "Malformed HTTP request."]], status: 400) }
                return
            }
            if isComplete {
                Task { await self.sendJSON(["error": ["type": "invalid_request", "message": "Incomplete HTTP request body."]], status: 400) }
            } else {
                self.receiveNext()
            }
        }
    }

    private static func parse(_ buffer: inout Data) throws -> HTTPIncomingRequest? {
        let separator = Data([13, 10, 13, 10])
        guard let marker = buffer.range(of: separator) else { return nil }
        guard let headerText = String(data: buffer[..<marker.lowerBound], encoding: .utf8) else { throw HTTPParseError.badRequest }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw HTTPParseError.badRequest }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3, requestParts[2].hasPrefix("HTTP/1.") else { throw HTTPParseError.badRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError.badRequest }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard headers[key] == nil else { throw HTTPParseError.badRequest }
            headers[key] = value
        }
        guard headers["transfer-encoding"] == nil else { throw HTTPParseError.badRequest }
        let contentLength = Int(headers["content-length"] ?? "0")
        guard let contentLength, contentLength >= 0 else { throw HTTPParseError.badRequest }
        guard contentLength <= 24 * 1024 * 1024 else { throw HTTPParseError.tooLarge }
        let bodyStart = marker.upperBound
        guard buffer.count >= bodyStart + contentLength else { return nil }
        let body = Data(buffer[bodyStart..<(bodyStart + contentLength)])
        buffer.removeAll(keepingCapacity: false)
        return HTTPIncomingRequest(method: String(requestParts[0]), target: String(requestParts[1]), headers: headers, body: body)
    }

    private static func reasonPhrase(_ status: Int) -> String {
        return switch status {
        case 200: "OK"
        case 201: "Created"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 422: "Unprocessable Content"
        case 499: "Client Closed Request"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        case 507: "Insufficient Storage"
        default: "Error"
        }
    }
}

final class HTTPServer {
    private let port: UInt16
    private let apiKey: String
    private let allowLAN: Bool
    private let inference: InferenceService
    private let inferenceDefaults: InferenceDefaults
    private let metrics: MetricsService
    private let logs: LogService
    private let queue = DispatchQueue(label: "jp.localai.iphone-server.http", qos: .userInitiated)
    private var listener: NWListener?

    init(port: UInt16, apiKey: String, allowLAN: Bool, inference: InferenceService, inferenceDefaults: InferenceDefaults = .standard, metrics: MetricsService, logs: LogService) {
        self.port = port
        self.apiKey = apiKey
        self.allowLAN = allowLAN
        self.inference = inference
        self.inferenceDefaults = inferenceDefaults
        self.metrics = metrics
        self.logs = logs
    }

    func start() async throws {
        guard listener == nil else { return }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "HTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid TCP port."])
        }
        let parameters = NWParameters.tcp
        let newListener: NWListener
        if !allowLAN {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: endpointPort)
            newListener = try NWListener(using: parameters)
        } else {
            newListener = try NWListener(using: parameters, on: endpointPort)
        }
        listener = newListener
        newListener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let session = HTTPConnectionSession(connection: connection)
            session.requestHandler = { [weak self] request, session in
                guard let self else { return }
                Task { await self.handle(request, on: session) }
            }
            session.start(queue: self.queue)
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var completed = false
                newListener.stateUpdateHandler = { state in
                    switch state {
                    case .ready where !completed:
                        completed = true
                        continuation.resume()
                    case let .failed(error) where !completed:
                        completed = true
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
                newListener.start(queue: queue)
            }
        } catch {
            newListener.cancel()
            listener = nil
            throw error
        }
        await logs.write(.info, event: "http_server_started", details: "port=\(port)")
    }

    func stop() async {
        listener?.cancel()
        listener = nil
        await logs.write(.info, event: "http_server_stopped")
    }

    private func handle(_ request: HTTPIncomingRequest, on session: HTTPConnectionSession) async {
        let url = URLComponents(string: "http://localhost\(request.target)")
        let path = url?.path ?? request.target
        if request.method == "GET", path == "/health" {
            let active = await inference.activeModel()
            await session.sendJSON(["status": "ok", "model_loaded": active.loaded, "model": jsonValue(active.id)], status: 200)
            return
        }
        guard isAuthorized(request.headers["authorization"]) else {
            await session.sendJSON(["error": ["type": "authentication_error", "message": "A valid bearer token is required."]], status: 401)
            return
        }

        switch (request.method, path) {
        case ("GET", "/v1/models"):
            await session.sendJSON(["object": "list", "data": await inference.modelList()], status: 200)
        case ("GET", "/capabilities"):
            let active = await inference.activeModel()
            let backend = await inference.capabilities()
            let backendMetrics = await inference.backendMetrics()
            let response: [String: Any] = [
                "server": "iphone-local-ai",
                "backend": active.backend,
                "model": jsonValue(active.id),
                "modalities": ["text": backend.text, "image": backend.image, "audio": backend.audio, "camera": false],
                "features": ["streaming": backend.streaming, "tools": false, "usb_forwarding": false, "mtp": backendMetrics.multiTokenPredictionEnabled]
            ]
            await session.sendJSON(response, status: 200)
        case ("GET", "/metrics"):
            do {
                var response = try await jsonObject(from: await metrics.snapshot()) as? [String: Any] ?? [:]
                let footprint = response.removeValue(forKey: "physical_footprint_mb") ?? NSNull()
                response["memory"] = ["physical_footprint_mb": footprint]
                let backendMetrics = await inference.backendMetrics()
                response["backend_runtime"] = jsonValue(backendMetrics.computeBackend)
                response["model_load_milliseconds"] = jsonValue(backendMetrics.modelLoadMilliseconds)
                response["multi_token_prediction_enabled"] = backendMetrics.multiTokenPredictionEnabled
                await session.sendJSON(response, status: 200)
            } catch {
                await sendError(type: "internal_error", message: "Could not encode metrics.", requestID: nil, status: 500, on: session)
            }
        case ("GET", "/logs"):
            do {
                await session.sendJSON(try await jsonObject(from: await logs.list()), status: 200)
            } catch {
                await sendError(type: "internal_error", message: "Could not encode logs.", requestID: nil, status: 500, on: session)
            }
        case ("POST", "/v1/chat/completions"):
            await handleChat(request.body, on: session)
        default:
            let status = ["GET", "POST"].contains(request.method) ? 404 : 405
            await session.sendJSON(["error": ["type": "invalid_request", "message": "Route not found."]], status: status)
        }
    }

    private func handleChat(_ body: Data, on session: HTTPConnectionSession) async {
        let adapted: AdaptedChatRequest
        do {
            adapted = try OpenAIRequestAdapter.adapt(body, defaults: inferenceDefaults)
        } catch let error as RequestValidationError {
            let type: String
            if case .unsupportedModality = error { type = "unsupported_modality" }
            else { type = "invalid_request" }
            await sendError(type: type, message: error.localizedDescription, requestID: nil, status: 400, on: session)
            return
        } catch {
            await sendError(type: "invalid_request", message: "Invalid chat completion request.", requestID: nil, status: 400, on: session)
            return
        }

        let request = adapted.inferenceRequest
        let stream: AsyncThrowingStream<InferenceChunk, Error>
        do {
            stream = try await inference.generate(request)
        } catch {
            let mapped = map(error)
            await sendError(type: mapped.type, message: mapped.message, requestID: request.id, status: mapped.status, on: session)
            return
        }

        if adapted.stream {
            do {
                try await session.beginEventStream()
                let created = Int(Date().timeIntervalSince1970)
                try await session.sendEvent(completionChunk(requestID: request.id, created: created, model: request.model, delta: ["role": "assistant"], finishReason: NSNull()))
                for try await chunk in stream {
                    if !chunk.text.isEmpty {
                        try await session.sendEvent(completionChunk(requestID: request.id, created: created, model: request.model, delta: ["content": chunk.text], finishReason: NSNull()))
                    }
                    if let finishReason = chunk.finishReason {
                        try await session.sendEvent(completionChunk(requestID: request.id, created: created, model: request.model, delta: [:], finishReason: finishReason))
                    }
                }
                try await session.sendDone()
            } catch {
                let mapped = map(error)
                await session.sendStreamError(["error": ["type": mapped.type, "message": mapped.message, "request_id": request.id]])
            }
            return
        }

        var content = ""
        var finishReason = "stop"
        do {
            for try await chunk in stream {
                content += chunk.text
                if let reason = chunk.finishReason { finishReason = reason }
            }
        } catch {
            let mapped = map(error)
            await sendError(type: mapped.type, message: mapped.message, requestID: request.id, status: mapped.status, on: session)
            return
        }
        let promptTokenCount = estimatedTokenCount(request.messages)
        let completionTokenCount = max(1, content.split(whereSeparator: \.isWhitespace).count)
        let response: [String: Any] = [
            "id": "chatcmpl-\(request.id)",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": request.model,
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": content],
                "finish_reason": finishReason
            ]],
            "usage": [
                "prompt_tokens": promptTokenCount,
                "completion_tokens": completionTokenCount,
                "total_tokens": promptTokenCount + completionTokenCount
            ]
        ]
        await session.sendJSON(response, status: 200)
    }

    private func sendError(type: String, message: String, requestID: String?, status: Int, on session: HTTPConnectionSession) async {
        var error: [String: Any] = ["type": type, "message": message]
        if let requestID { error["request_id"] = requestID }
        await session.sendJSON(["error": error], status: status)
    }

    private func isAuthorized(_ header: String?) -> Bool {
        BearerTokenAuthenticator.matches(header, expectedToken: apiKey)
    }

    private func completionChunk(requestID: String, created: Int, model: String, delta: [String: Any], finishReason: Any) -> [String: Any] {
        [
            "id": "chatcmpl-\(requestID)",
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [["index": 0, "delta": delta, "finish_reason": finishReason]]
        ]
    }

    private func estimatedTokenCount(_ messages: [InferenceMessage]) -> Int {
        max(1, messages.flatMap(\.parts).compactMap { part -> String? in
            if case let .text(text) = part { return text }
            return nil
        }.joined(separator: " ").split(whereSeparator: \.isWhitespace).count)
    }

    private func jsonObject<T: Encodable>(from value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func jsonValue<T>(_ value: T?) -> Any {
        guard let value else { return NSNull() }
        return value
    }

    private func map(_ error: Error) -> (type: String, message: String, status: Int) {
        if error is CancellationError {
            return ("generation_cancelled", "Generation was cancelled.", 499)
        }
        let description = error.localizedDescription.lowercased()
        if description.contains("out of memory") || description.contains("insufficient memory") || description.contains("allocation failed") {
            return ("out_of_memory", error.localizedDescription, 507)
        }
        if let error = error as? InferenceError {
            switch error {
            case .modelNotLoaded: return ("model_not_loaded", error.localizedDescription, 409)
            case .modelNotFound: return ("model_not_found", error.localizedDescription, 404)
            case .unsupportedModality: return ("unsupported_modality", error.localizedDescription, 400)
            case .backendUnavailable: return ("backend_error", error.localizedDescription, 501)
            case .requestInProgress: return ("server_busy", error.localizedDescription, 503)
            case .outOfMemory: return ("out_of_memory", error.localizedDescription, 507)
            case .thermalLimit: return ("thermal_limit", error.localizedDescription, 503)
            case .generationCancelled: return ("generation_cancelled", error.localizedDescription, 499)
            }
        }
        return ("backend_error", error.localizedDescription, 500)
    }
}
