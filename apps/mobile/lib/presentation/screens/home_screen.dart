import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:camsync_protocol/camsync_protocol.dart';
import '../../core/network/stream_server.dart';
import '../../features/camera/camera_channel.dart';
import '../../features/telemetry/battery_monitor.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final MobileStreamServer _streamServer = MobileStreamServer();
  final CameraChannel _cameraChannel = CameraChannel();
  final BatteryMonitor _batteryMonitor = BatteryMonitor();

  bool _isStreaming = false;
  bool _oledPowerSave = false;
  int? _textureId;
  int _clientCount = 0;
  String _localIp = 'Discovering...';

  CameraResolution _selectedResolution = CameraResolution.fhd1080;
  int _selectedFps = 60;
  CameraLens _selectedLens = CameraLens.backWide;
  bool _torchEnabled = false;
  double _currentZoom = 1.0;

  DeviceTelemetry _lastTelemetry = const DeviceTelemetry(
    batteryLevel: 100,
    isCharging: false,
    thermalState: 'nominal',
    temperatureC: 30.0,
    encoderBitrateKbps: 0,
    currentFps: 0.0,
  );

  StreamSubscription? _packetSub;
  StreamSubscription? _controlSub;
  StreamSubscription? _telemetrySub;
  StreamSubscription? _clientCountSub;

  @override
  void initState() {
    super.initState();
    _initNetwork();
    _setupListeners();
    WakelockPlus.enable();
  }

  Future<void> _initNetwork() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            setState(() {
              _localIp = addr.address;
            });
            break;
          }
        }
      }
    } catch (_) {}

    await _streamServer.start();
  }

  void _setupListeners() {
    // 1. Listen for video frames emitted from native encoder and forward over TCP
    _packetSub = _cameraChannel.onVideoPacket.listen((packetBytes) {
      _streamServer.broadcastRawVideoBytes(packetBytes);
      _batteryMonitor.recordFrameSent(packetBytes.length);
    });

    // 2. Listen for remote control RPC commands from PC
    _controlSub = _streamServer.onControlMessage.listen((msg) {
      _handleControlMessage(msg);
    });

    // 3. Listen for telemetry updates and broadcast to PC
    _telemetrySub = _batteryMonitor.onTelemetry.listen((telemetry) {
      setState(() {
        _lastTelemetry = telemetry;
      });
      _streamServer.broadcastControlMessage(
        ControlRpcMessage.telemetryNotification(telemetry: telemetry),
      );
    });

    // 4. Client count
    _clientCountSub = _streamServer.onClientCountChanged.listen((count) {
      setState(() {
        _clientCount = count;
      });
    });

    _batteryMonitor.start();
  }

  void _handleControlMessage(ControlRpcMessage msg) {
    if (msg.method == 'camera.setParameters' && msg.params != null) {
      final params = CameraParameters.fromJson(msg.params!);
      setState(() {
        _selectedResolution = params.resolution;
        _selectedFps = params.fps;
        _selectedLens = params.lens;
        _torchEnabled = params.torch;
        _currentZoom = params.zoom;
        _oledPowerSave = params.oledPowerSave;
      });

      _cameraChannel.setTorch(_torchEnabled);
      _cameraChannel.setZoom(_currentZoom);
      _cameraChannel.setFocus(params.focusMode, params.focusDistance);
      _cameraChannel.setExposure(params.exposureMode, params.iso, params.shutterSpeedMs);
    } else if (msg.method == 'stream.start') {
      _toggleStreaming(forceState: true);
    } else if (msg.method == 'stream.stop') {
      _toggleStreaming(forceState: false);
    }
  }

  Future<void> _toggleStreaming({bool? forceState}) async {
    final targetState = forceState ?? !_isStreaming;
    if (targetState == _isStreaming) return;

    if (targetState) {
      final textureId = await _cameraChannel.startCapture(
        resolution: _selectedResolution,
        fps: _selectedFps,
        lens: _selectedLens,
      );
      if (textureId != null) {
        setState(() {
          _isStreaming = true;
          _textureId = textureId;
        });
      }
    } else {
      await _cameraChannel.stopCapture();
      setState(() {
        _isStreaming = false;
        _torchEnabled = false;
        _textureId = null;
      });
    }
  }

  void _switchLens(CameraLens lens) async {
    setState(() => _selectedLens = lens);
    if (_isStreaming) {
      final textureId = await _cameraChannel.startCapture(
        resolution: _selectedResolution,
        fps: _selectedFps,
        lens: lens,
      );
      if (textureId != null) {
        setState(() => _textureId = textureId);
      }
    } else {
      _cameraChannel.setLens(lens);
    }
  }

  void _toggleTorch() {
    setState(() => _torchEnabled = !_torchEnabled);
    _cameraChannel.setTorch(_torchEnabled);
  }

  @override
  void dispose() {
    _packetSub?.cancel();
    _controlSub?.cancel();
    _telemetrySub?.cancel();
    _clientCountSub?.cancel();
    _batteryMonitor.dispose();
    _streamServer.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // If OLED power save is active, render full pitch black screen
    if (_oledPowerSave) {
      return GestureDetector(
        onTap: () => setState(() => _oledPowerSave = false),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.videocam, color: Colors.greenAccent, size: 36),
                const SizedBox(height: 12),
                Text(
                  'CamSync OLED Power Saver Active',
                  style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 13),
                ),
                const SizedBox(height: 6),
                Text(
                  'Tap anywhere to wake display',
                  style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 11),
                ),
                const SizedBox(height: 16),
                Text(
                  '${_lastTelemetry.currentFps.toStringAsFixed(0)} FPS  •  ${(_lastTelemetry.encoderBitrateKbps / 1000).toStringAsFixed(1)} Mbps  •  ${_lastTelemetry.batteryLevel}%',
                  style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFF101216),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161920),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: _isStreaming ? Colors.green.withOpacity(0.2) : Colors.blue.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                _isStreaming ? Icons.videocam : Icons.videocam_outlined,
                color: _isStreaming ? Colors.greenAccent : Colors.lightBlueAccent,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'CamSync',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'OLED Power Saver (Dim Screen)',
            icon: const Icon(Icons.brightness_2_outlined, color: Colors.white70),
            onPressed: () => setState(() => _oledPowerSave = true),
          ),
          IconButton(
            tooltip: 'Fill Light (Torch)',
            icon: Icon(
              _torchEnabled ? Icons.flash_on : Icons.flash_off,
              color: _torchEnabled ? Colors.amberAccent : Colors.white70,
            ),
            onPressed: _toggleTorch,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Status and Telemetry Pill
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF1E222B),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _isStreaming ? Colors.greenAccent.withOpacity(0.4) : Colors.white12,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: _isStreaming ? Colors.greenAccent : Colors.orangeAccent,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _isStreaming ? 'Streaming Active' : 'Ready / Standby',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'IP: $_localIp:8282  |  Clients: $_clientCount',
                        style: const TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${_lastTelemetry.currentFps.toStringAsFixed(0)} FPS • ${(_lastTelemetry.encoderBitrateKbps / 1000).toStringAsFixed(1)} Mbps',
                        style: const TextStyle(
                          color: Colors.lightBlueAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            _lastTelemetry.isCharging ? Icons.battery_charging_full : Icons.battery_std,
                            size: 14,
                            color: Colors.white70,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${_lastTelemetry.batteryLevel}%',
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Live Camera Viewfinder
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white10),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: _isStreaming && _textureId != null
                      ? Stack(
                          fit: StackFit.expand,
                          children: [
                            Center(
                              child: AspectRatio(
                                aspectRatio: _selectedResolution.width / _selectedResolution.height,
                                child: Texture(textureId: _textureId!),
                              ),
                            ),
                            Positioned(
                              top: 12,
                              left: 12,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: const BoxDecoration(
                                        color: Colors.redAccent,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    const Text(
                                      'LIVE PREVIEW',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        )
                      : Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(
                                Icons.no_photography_outlined,
                                size: 64,
                                color: Colors.white24,
                              ),
                              SizedBox(height: 16),
                              Text(
                                'Press Start to begin streaming',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w500,
                                  fontSize: 16,
                                ),
                              ),
                              SizedBox(height: 8),
                              Text(
                                'Connect Windows PC via Wi-Fi or USB cable',
                                style: TextStyle(color: Colors.white38, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ),

            // Lens Selector Bar
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildLensChip(CameraLens.backUltraWide, '0.5x'),
                  const SizedBox(width: 8),
                  _buildLensChip(CameraLens.backWide, '1x'),
                  const SizedBox(width: 8),
                  _buildLensChip(CameraLens.backTelephoto, '3x'),
                  const SizedBox(width: 8),
                  _buildLensChip(CameraLens.front, 'Front'),
                ],
              ),
            ),

            // Bottom Action Bar
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                color: Color(0xFF161920),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Row(
                children: [
                  // Resolution Picker
                  DropdownButton<CameraResolution>(
                    dropdownColor: const Color(0xFF1E222B),
                    value: _selectedResolution,
                    underline: const SizedBox(),
                    items: const [
                      DropdownMenuItem(value: CameraResolution.hd720, child: Text('720p', style: TextStyle(color: Colors.white))),
                      DropdownMenuItem(value: CameraResolution.fhd1080, child: Text('1080p', style: TextStyle(color: Colors.white))),
                      DropdownMenuItem(value: CameraResolution.uhd4k, child: Text('4K UHD', style: TextStyle(color: Colors.white))),
                    ],
                    onChanged: _isStreaming
                        ? null
                        : (res) {
                            if (res != null) setState(() => _selectedResolution = res);
                          },
                  ),
                  const SizedBox(width: 12),

                  // FPS Picker
                  DropdownButton<int>(
                    dropdownColor: const Color(0xFF1E222B),
                    value: _selectedFps,
                    underline: const SizedBox(),
                    items: const [
                      DropdownMenuItem(value: 30, child: Text('30 FPS', style: TextStyle(color: Colors.white))),
                      DropdownMenuItem(value: 60, child: Text('60 FPS', style: TextStyle(color: Colors.white))),
                    ],
                    onChanged: _isStreaming
                        ? null
                        : (fps) {
                            if (fps != null) setState(() => _selectedFps = fps);
                          },
                  ),
                  const Spacer(),

                  // Start / Stop Streaming Button
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isStreaming ? Colors.redAccent : Colors.blueAccent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: () => _toggleStreaming(),
                    icon: Icon(_isStreaming ? Icons.stop : Icons.play_arrow),
                    label: Text(
                      _isStreaming ? 'Stop' : 'Start Stream',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLensChip(CameraLens lens, String label) {
    final isSelected = _selectedLens == lens;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      selectedColor: Colors.blueAccent,
      backgroundColor: const Color(0xFF1E222B),
      labelStyle: TextStyle(
        color: isSelected ? Colors.white : Colors.white70,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
      ),
      onSelected: (_) => _switchLens(lens),
    );
  }
}
