import Foundation
import Network

class VideoStreamingServer {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "com.camsync.videoserver", qos: .userInteractive)
    private let port: UInt16
    private var isRunning = false
    private var cachedConfigPackets: [Data] = []

    init(port: UInt16 = 8282) {
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
                print("[VideoStreamingServer] Invalid port: \(port)")
                return
            }

            let listener = try NWListener(using: params, on: endpointPort)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    print("[VideoStreamingServer] Native Video Server listening on port \(self.port)")
                case .failed(let error):
                    print("[VideoStreamingServer] Failed on port \(self.port): \(error)")
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            listener.start(queue: queue)
        } catch {
            print("[VideoStreamingServer] Error starting listener: \(error)")
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        queue.async {
            self.connections.append(connection)
            print("[VideoStreamingServer] PC connected: \(connection.endpoint) (Total: \(self.connections.count))")

            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self = self, let connection = connection else { return }
                switch state {
                case .failed, .cancelled:
                    self.queue.async {
                        self.connections.removeAll { $0 === connection }
                        print("[VideoStreamingServer] PC disconnected. Remaining: \(self.connections.count)")
                    }
                default:
                    break
                }
            }

            connection.start(queue: self.queue)

            // Immediately dispatch SPS and PPS config packets so the Windows decoder initializes instantly
            for config in self.cachedConfigPackets {
                connection.send(content: config, completion: .idempotent)
            }
        }
    }

    func broadcastPacket(_ data: Data) {
        queue.async {
            // Type 1: Config packet (SPS/PPS) -> Cache for new connections
            if data.count >= 6 && data[5] == 1 {
                if self.cachedConfigPackets.count >= 2 {
                    self.cachedConfigPackets.removeAll()
                }
                self.cachedConfigPackets.append(data)
            }

            guard !self.connections.isEmpty else { return }
            for connection in self.connections {
                connection.send(content: data, completion: .idempotent)
            }
        }
    }

    func stop() {
        isRunning = false
        queue.async {
            for connection in self.connections {
                connection.cancel()
            }
            self.connections.removeAll()
            self.listener?.cancel()
            self.listener = nil
            self.cachedConfigPackets.removeAll()
            print("[VideoStreamingServer] Stopped")
        }
    }
}
