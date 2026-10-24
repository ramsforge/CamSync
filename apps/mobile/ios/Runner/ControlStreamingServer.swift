import Foundation
import Network

private class ControlClientConnection {
    let connection: NWConnection
    var buffer: String = ""

    init(connection: NWConnection) {
        self.connection = connection
    }
}

class ControlStreamingServer {
    private var listener: NWListener?
    private var clients: [ControlClientConnection] = []
    private let queue = DispatchQueue(label: "com.camsync.controlserver", qos: .userInitiated)
    private let port: UInt16
    private var isRunning = false

    var onMessageReceived: ((String) -> Void)?
    var onClientCountChanged: ((Int) -> Void)?

    init(port: UInt16 = 8283) {
        self.port = port
    }

    func start() {
        if isRunning { return }
        isRunning = true

        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true

            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                print("[ControlStreamingServer] Invalid port: \(port)")
                return
            }

            let listener = try NWListener(using: params, on: endpointPort)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    print("[ControlStreamingServer] Native Control Server listening on port \(self.port)")
                case .failed(let error):
                    print("[ControlStreamingServer] Failed on port \(self.port): \(error)")
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            listener.start(queue: queue)
        } catch {
            print("[ControlStreamingServer] Error starting listener: \(error)")
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        queue.async {
            let client = ControlClientConnection(connection: connection)
            self.clients.append(client)
            print("[ControlStreamingServer] PC connected for control: \(connection.endpoint) (Total: \(self.clients.count))")
            self.notifyClientCount()

            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self = self, let connection = connection else { return }
                switch state {
                case .failed, .cancelled:
                    self.queue.async {
                        self.clients.removeAll { $0.connection === connection }
                        print("[ControlStreamingServer] PC control disconnected. Remaining: \(self.clients.count)")
                        self.notifyClientCount()
                    }
                default:
                    break
                }
            }

            connection.start(queue: self.queue)
            self.receive(client: client)
        }
    }

    private func notifyClientCount() {
        let count = self.clients.count
        DispatchQueue.main.async {
            self.onClientCountChanged?(count)
        }
    }

    private func receive(client: ControlClientConnection) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            if let data = content, let text = String(data: data, encoding: .utf8) {
                client.buffer += text
                while let newlineRange = client.buffer.range(of: "\n") {
                    let line = String(client.buffer[..<newlineRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    client.buffer.removeSubrange(..<newlineRange.upperBound)
                    if !line.isEmpty {
                        self.processIncomingLine(line, from: client)
                    }
                }
            }

            if !isComplete && error == nil {
                self.receive(client: client)
            } else {
                self.queue.async {
                    self.clients.removeAll { $0 === client }
                    self.notifyClientCount()
                }
            }
        }
    }

    private func processIncomingLine(_ line: String, from client: ControlClientConnection) {
        // Forward raw line to Flutter MethodChannel listener
        DispatchQueue.main.async {
            self.onMessageReceived?(line)
        }

        // Automatic JSON-RPC 2.0 response if request has an id
        if let data = line.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = json["id"] {
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "result": true
            ]
            if let respData = try? JSONSerialization.data(withJSONObject: response),
               var respStr = String(data: respData, encoding: .utf8) {
                respStr += "\n"
                if let payload = respStr.data(using: .utf8) {
                    client.connection.send(content: payload, completion: .contentProcessed { _ in })
                }
            }
        }
    }

    func broadcastMessage(_ string: String) {
        queue.async {
            var text = string
            if !text.hasSuffix("\n") {
                text += "\n"
            }
            guard let data = text.data(using: .utf8) else { return }
            for client in self.clients {
                client.connection.send(content: data, completion: .contentProcessed { _ in })
            }
        }
    }

    func stop() {
        isRunning = false
        queue.async {
            for client in self.clients {
                client.connection.cancel()
            }
            self.clients.removeAll()
            self.listener?.cancel()
            self.listener = nil
            self.notifyClientCount()
            print("[ControlStreamingServer] Stopped")
        }
    }
}
