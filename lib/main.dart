import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ---------- Telegram Bot Configuration ----------
// Replace with your bot token (create via @BotFather on Telegram)
const String BOT_TOKEN = "YOUR_BOT_TOKEN_HERE";
const String TELEGRAM_API_BASE = "https://api.telegram.org/bot$BOT_TOKEN";

// ---------- Foreground Service Configuration ----------
const int POLL_INTERVAL_SECONDS = 10;

// ---------- Main App ----------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Request necessary permissions
  await _requestPermissions();

  // Initialize foreground service
  await FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'child_monitor_channel',
      channelName: 'Child Monitor Service',
      channelDescription: 'This service keeps the app connected to Telegram.',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
      iconData: null, // optional
    ),
    iosNotificationOptions: IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      interval: POLL_INTERVAL_SECONDS * 1000,
      autoStartOnBoot: true, // restart on boot
      allowWakelock: true,
      allowBackgroundAudio: false,
    ),
  );

  // Start the foreground service if not already running
  if (!await FlutterForegroundTask.isRunningService) {
    await FlutterForegroundTask.startService(
      notificationTitle: 'Child Monitor',
      notificationText: 'Waiting for commands...',
      callback: _startCallback,
    );
  }

  runApp(MyApp());
}

Future<void> _requestPermissions() async {
  // Android 13+ notification permission
  if (await Permission.notification.isDenied) {
    await Permission.notification.request();
  }
  // Storage permission (for older Android versions)
  if (await Permission.storage.isDenied) {
    await Permission.storage.request();
  }
  // For Android 11+, manage external storage might be needed for downloads
  if (await Permission.manageExternalStorage.isDenied) {
    await Permission.manageExternalStorage.request();
  }
  // Ensure the app can run in the background with wakelock
  await WakelockPlus.enable(); // enable by default, but will be managed by video player
}

// ---------- Foreground Service Callback ----------
@pragma('vm:entry-point')
void _startCallback() {
  FlutterForegroundTask.setTaskHandler(TaskHandler());
}

class TaskHandler extends TaskHandler {
  SendPort? _sendPort;

  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    _sendPort = sendPort;
    print('Foreground service started');
  }

  @override
  Future<void> onEvent(DateTime timestamp, SendPort? sendPort) async {
    _sendPort = sendPort;
    // This runs every POLL_INTERVAL_SECONDS
    await _checkTelegramBot(sendPort);
  }

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {
    print('Foreground service destroyed');
  }

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {}
}

// ---------- Telegram Bot Polling ----------
Future<void> _checkTelegramBot(SendPort? sendPort) async {
  try {
    // Get last processed update ID from SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    int? lastUpdateId = prefs.getInt('last_update_id');

    // Fetch updates from Telegram
    String url = '$TELEGRAM_API_BASE/getUpdates';
    if (lastUpdateId != null) {
      url += '?offset=${lastUpdateId + 1}';
    }

    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      Map<String, dynamic> data = jsonDecode(response.body);
      if (data['ok']) {
        List<dynamic> updates = data['result'];
        if (updates.isNotEmpty) {
          // Process each update
          for (var update in updates) {
            int updateId = update['update_id'];
            // Save last processed ID
            await prefs.setInt('last_update_id', updateId);

            // Check for command or video
            if (update.containsKey('message')) {
              var message = update['message'];
              // Text command: /url_video <URL>
              if (message.containsKey('text')) {
                String text = message['text'];
                if (text.startsWith('/url_video')) {
                  // Extract URL after command
                  String urlVideo = text.replaceFirst('/url_video', '').trim();
                  if (urlVideo.isNotEmpty) {
                    // Send to UI to play
                    _sendVideoToUI(sendPort, urlVideo, isUrl: true);
                  }
                }
              }
              // Video file upload
              else if (message.containsKey('video')) {
                // Video file sent directly
                var video = message['video'];
                String fileId = video['file_id'];
                // Download video file
                String filePath = await _downloadTelegramVideo(fileId);
                if (filePath != null) {
                  _sendVideoToUI(sendPort, filePath, isUrl: false);
                }
              }
            }
          }
        }
      }
    }
  } catch (e) {
    print('Error checking bot: $e');
  }
}

Future<String?> _downloadTelegramVideo(String fileId) async {
  try {
    // Get file path from Telegram
    final fileInfoUrl = '$TELEGRAM_API_BASE/getFile?file_id=$fileId';
    final fileInfoRes = await http.get(Uri.parse(fileInfoUrl));
    if (fileInfoRes.statusCode == 200) {
      Map<String, dynamic> fileInfo = jsonDecode(fileInfoRes.body);
      if (fileInfo['ok']) {
        String filePath = fileInfo['result']['file_path'];
        String downloadUrl = 'https://api.telegram.org/file/bot$BOT_TOKEN/$filePath';

        // Download file
        final response = await http.get(Uri.parse(downloadUrl));
        if (response.statusCode == 200) {
          // Save to app's temporary directory
          final dir = await getTemporaryDirectory();
          final file = File('${dir.path}/video_${DateTime.now().millisecondsSinceEpoch}.mp4');
          await file.writeAsBytes(response.bodyBytes);
          return file.path;
        }
      }
    }
  } catch (e) {
    print('Error downloading video: $e');
  }
  return null;
}

void _sendVideoToUI(SendPort? sendPort, String videoPathOrUrl, {bool isUrl = false}) {
  if (sendPort != null) {
    sendPort.send({
      'type': 'play_video',
      'video': videoPathOrUrl,
      'isUrl': isUrl,
    });
  }
}

// ---------- UI: Main App ----------
class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  ReceivePort? _receivePort;

  @override
  void initState() {
    super.initState();
    _initReceivePort();
    // Listen for foreground service events
    FlutterForegroundTask.addTaskDataCallback(_onTaskDataReceived);
  }

  void _initReceivePort() {
    _receivePort = ReceivePort();
    _receivePort!.listen((data) {
      _onTaskDataReceived(data);
    });
    FlutterForegroundTask.setTaskData(_receivePort!.sendPort);
  }

  void _onTaskDataReceived(dynamic data) {
    if (data is Map && data['type'] == 'play_video') {
      String video = data['video'];
      bool isUrl = data['isUrl'];
      // Navigate to video player screen
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => VideoPlayerScreen(video: video, isUrl: isUrl),
        ),
      );
    }
  }

  @override
  void dispose() {
    _receivePort?.close();
    FlutterForegroundTask.removeTaskDataCallback();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Child Monitor',
      theme: ThemeData.dark(),
      home: HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isServiceRunning = false;

  @override
  void initState() {
    super.initState();
    _checkServiceStatus();
  }

  Future<void> _checkServiceStatus() async {
    bool running = await FlutterForegroundTask.isRunningService;
    setState(() {
      _isServiceRunning = running;
    });
  }

  Future<void> _startService() async {
    await FlutterForegroundTask.startService(
      notificationTitle: 'Child Monitor',
      notificationText: 'Waiting for commands...',
      callback: _startCallback,
    );
    _checkServiceStatus();
  }

  Future<void> _stopService() async {
    await FlutterForegroundTask.stopService();
    _checkServiceStatus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Child Monitor')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _isServiceRunning
                  ? 'Service is running\nWaiting for Telegram commands...'
                  : 'Service is stopped',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: _isServiceRunning ? _stopService : _startService,
              child: Text(_isServiceRunning ? 'Stop Service' : 'Start Service'),
            ),
            SizedBox(height: 20),
            Text(
              'Bot Commands:\n'
              'Send: /url_video [URL] - to play video from URL\n'
              'Send a video file - to play uploaded video',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- Video Player Screen ----------
class VideoPlayerScreen extends StatefulWidget {
  final String video; // Can be URL or local file path
  final bool isUrl;

  VideoPlayerScreen({required this.video, required this.isUrl});

  @override
  _VideoPlayerScreenState createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
    // Keep screen on while video plays
    WakelockPlus.enable();
  }

  Future<void> _initializeVideo() async {
    if (widget.isUrl) {
      _controller = VideoPlayerController.network(widget.video);
    } else {
      _controller = VideoPlayerController.file(File(widget.video));
    }
    await _controller.initialize();
    setState(() {
      _isInitialized = true;
    });
    _controller.play();
  }

  @override
  void dispose() {
    _controller.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Playing Video')),
      body: _isInitialized
          ? Center(
              child: AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: VideoPlayer(_controller),
              ),
            )
          : Center(child: CircularProgressIndicator()),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          setState(() {
            _controller.value.isPlaying
                ? _controller.pause()
                : _controller.play();
          });
        },
        child: Icon(
          _controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
        ),
      ),
    );
  }
}