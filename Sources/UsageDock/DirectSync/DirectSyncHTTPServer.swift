import Foundation
import Network
import TokenRemainSyncKit

struct DirectSyncHTTPRequest: Sendable {
    let method: String
    let path: String
    let body: Data
}

struct DirectSyncHTTPResponse: Sendable {
    let status: Int
    let contentType: String
    let body: Data

    static func json(_ body: Data, status: Int = 200) -> DirectSyncHTTPResponse {
        DirectSyncHTTPResponse(status: status, contentType: "application/json", body: body)
    }

    static func text(_ message: String, status: Int) -> DirectSyncHTTPResponse {
        DirectSyncHTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(message.utf8))
    }
}

final class DirectSyncHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (DirectSyncHTTPRequest) async -> DirectSyncHTTPResponse

    private static let maximumRequestBytes = 48 * 1024
    private static let maximumHeaderBytes = 16 * 1024
    private let queue = DispatchQueue(label: "com.jamesli.tokenremain.direct-sync.http")
    private var listener: NWListener?
    private var handler: Handler?

    func start(
        port: UInt16 = DirectSyncConstants.defaultPort,
        handler: @escaping Handler,
        stateChanged: @escaping @Sendable (NWListener.State) -> Void
    ) throws {
        guard listener == nil else { return }
        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            throw DirectSyncHTTPServerError.invalidPort
        }
        let listener = try NWListener(using: .tcp, on: networkPort)
        self.handler = handler
        self.listener = listener
        listener.stateUpdateHandler = stateChanged
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        handler = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.receive(connection, buffer: Data())
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }
            guard next.count <= Self.maximumRequestBytes else {
                self.send(.text("Request too large", status: 413), on: connection)
                return
            }

            switch Self.parse(next) {
            case .request(let request):
                guard let handler = self.handler else {
                    self.send(.text("Server unavailable", status: 503), on: connection)
                    return
                }
                Task {
                    let response = await handler(request)
                    self.queue.async { self.send(response, on: connection) }
                }
            case .needMore:
                if isComplete || error != nil {
                    self.send(.text("Malformed HTTP request", status: 400), on: connection)
                } else {
                    self.receive(connection, buffer: next)
                }
            case .failure(let response):
                self.send(response, on: connection)
            }
        }
    }

    private func send(_ response: DirectSyncHTTPResponse, on connection: NWConnection) {
        let statusText: String = switch response.status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 429: "Too Many Requests"
        case 503: "Service Unavailable"
        default: "Error"
        }
        let header = "HTTP/1.1 \(response.status) \(statusText)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        connection.send(content: Data(header.utf8) + response.body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private enum ParseResult {
        case request(DirectSyncHTTPRequest)
        case needMore
        case failure(DirectSyncHTTPResponse)
    }

    private static func parse(_ data: Data) -> ParseResult {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter) else {
            return data.count > maximumHeaderBytes
                ? .failure(.text("Headers too large", status: 413))
                : .needMore
        }
        guard headerRange.lowerBound <= maximumHeaderBytes,
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return .failure(.text("Malformed headers", status: 400))
        }
        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" else {
            return .failure(.text("HTTP/1.1 required", status: 400))
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                return .failure(.text("Malformed header", status: 400))
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, headers[name] == nil else {
                return .failure(.text("Duplicate header", status: 400))
            }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil,
              let contentLength = Int(headers["content-length"] ?? "0"),
              (0...(EncryptedSyncEnvelope.maximumEncodedEnvelopeBytes)).contains(contentLength) else {
            return .failure(.text("Invalid Content-Length", status: 400))
        }
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return .needMore }
        let body = Data(data[bodyStart..<(bodyStart + contentLength)])
        return .request(
            DirectSyncHTTPRequest(
                method: String(requestLine[0]),
                path: String(requestLine[1]),
                body: body
            )
        )
    }
}

enum DirectSyncHTTPServerError: Error {
    case invalidPort
}
