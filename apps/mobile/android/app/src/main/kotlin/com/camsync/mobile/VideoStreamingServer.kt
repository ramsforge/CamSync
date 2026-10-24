package com.camsync.mobile

import android.util.Log
import java.io.IOException
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList

class VideoStreamingServer(private val port: Int = 8282) {
    companion object {
        private const val TAG = "CamSyncVideoServer"
    }

    private var serverSocket: ServerSocket? = null
    private var acceptThread: Thread? = null
    private val clientSockets = CopyOnWriteArrayList<Socket>()
    @Volatile private var isRunning = false

    fun start() {
        if (isRunning) return
        isRunning = true

        acceptThread = Thread {
            try {
                val server = ServerSocket(port)
                server.reuseAddress = true
                serverSocket = server
                Log.i(TAG, "Native Video Streaming Server listening on port $port")

                while (isRunning && !server.isClosed) {
                    try {
                        val client = server.accept()
                        client.tcpNoDelay = true
                        client.sendBufferSize = 256 * 1024
                        clientSockets.add(client)
                        Log.i(TAG, "PC client connected to native video stream: ${client.remoteSocketAddress} (Total: ${clientSockets.size})")
                    } catch (e: IOException) {
                        if (isRunning) {
                            Log.w(TAG, "Accept error: ${e.message}")
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Server socket error on port $port: ${e.message}", e)
            }
        }.apply {
            name = "CamSyncVideoAcceptThread"
            start()
        }
    }

    fun broadcastPacket(packetBytes: ByteArray) {
        if (clientSockets.isEmpty()) return

        for (client in clientSockets) {
            try {
                val out = client.getOutputStream()
                out.write(packetBytes)
                out.flush()
            } catch (e: Exception) {
                Log.i(TAG, "Client disconnected: ${client.remoteSocketAddress}")
                try {
                    client.close()
                } catch (_: Exception) {}
                clientSockets.remove(client)
            }
        }
    }

    fun stop() {
        isRunning = false
        try {
            serverSocket?.close()
        } catch (_: Exception) {}
        serverSocket = null

        for (client in clientSockets) {
            try {
                client.close()
            } catch (_: Exception) {}
        }
        clientSockets.clear()

        try {
            acceptThread?.interrupt()
            acceptThread = null
        } catch (_: Exception) {}

        Log.i(TAG, "Native Video Streaming Server stopped.")
    }
}
