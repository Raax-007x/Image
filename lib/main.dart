import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const String BOT_TOKEN = "YOUR_BOT_TOKEN_HERE";
const String TELEGRAM_API_BASE = "https://api.telegram.org/bot$BOT_TOKEN";

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _requestPermissions();

  // ERROR FIXED: init() void return karta hai, await nahi chahiye
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'child_monitor_channel',
      channelName: 'Child Monitor Service',
      channelDescription: 'Keeps app connected to Telegram.',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: const ForegroundTaskOptions(
      interval: 10000,
      autoRunOnBoot: true, // ERROR FIXED: autoStartOnBoot ki jagah autoRunOnBoot
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );

  runApp(MyApp());
}

Future<void> _requestPermissions() async {
  if (await Permission.notification.isDenied) await Permission.notification.request();
  if (await Permission.storage.isDenied) await Permission.storage.request();
  if (await Permission.manageExternalStorage.isDenied) await Permission.manageExternalStorage.request();
  await WakelockPlus.enable();
}

@pragma('vm:entry-point')
void _startCallback() {
  FlutterForegroundTask.setTaskHandler(MyTaskHandler()); // ERROR FIXED: Name changed
}

// ERROR FIXED: Class name MyTaskHandler kar diya
class MyTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    print('Foreground service started');
  }

  @override
  Future<void> onEvent(DateTime timestamp, SendPort? sendPort) async {
    await _checkTelegramBot(sendPort);
  }

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {}
  @override
  void onNotificationButtonPressed(String id) {}
  @override
  void onNotificationPressed() {}
}

Future<void> _checkTelegramBot(SendPort? sendPort) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    int? lastUpdateId = prefs.getInt('last_update_id');

    String url = '$TELEGRAM_API_BASE/getUpdates';
    if (lastUpdateId != null) url += '?offset=${lastUpdateId + 1}';

    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      Map<String, dynamic> data = jsonDecode(response.body);
      if (data['ok']) {
        List<dynamic> updates = data['result'];
        for (var update in updates) {
          int updateId = update['update_id'];
          await prefs.setInt('last_update_id', updateId);

          if (update.containsKey('message')) {
            var message = update['message'];
            if (message.containsKey('text')) {
              String text = message['text'];
              if (text.startsWith('/url_video')) {
                String urlVideo = text.replaceFirst('/url_video', '').trim();
                if (urlVideo.isNotEmpty) _sendVideoToUI(urlVideo, isUrl: true);
              }
            } else if (message.containsKey('video')) {
              String fileId = message['video']['file_id'];
              String? filePath = await _downloadTelegramVideo(fileId); // ERROR FIXED: String? lagaya
              if (filePath != null) _sendVideoToUI(filePath, isUrl: false);
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
    final fileInfoRes = await http.get(Uri.parse('$TELEGRAM_API_BASE/getFile?file_id=$fileId'));
    if (fileInfoRes.statusCode == 200) {
      Map<String, dynamic> fileInfo = jsonDecode(fileInfoRes.body);
      if (fileInfo['ok']) {
        String filePath = fileInfo['result']['file_path'];
        final response = await http.get(Uri.parse('https://api.telegram.org/file/bot$BOT_TOKEN/$filePath'));
        if (response.statusCode == 200) {
          final dir = await getTemporaryDirectory();
          final file = File('${dir.path}/video_${DateTime.now().millisecondsSinceEpoch}.mp4');
          await file.writeAsBytes(response.bodyBytes);
          return file.path;
        }
      }
    }
  } catch (e) { print('Download error: $e'); }
  return null;
}

void _sendVideoToUI(String videoPathOrUrl, {bool isUrl = false}) {
  // ERROR FIXED: Naya tarika data UI me bhejne ka
  FlutterForegroundTask.sendDataToMain({
    'type': 'play_video',
    'video': videoPathOrUrl,
    'isUrl': isUrl,
  });
}

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  ReceivePort? _receivePort;

  @override
  void initState() {
    super.initState();
    _initForegroundTask();
  }

  void _initForegroundTask() {
    // ERROR FIXED: addTaskDataCallback hata kar naya method use kiya
    FlutterForegroundTask.initReceivePort(_receivePort);
    FlutterForegroundTask.receivePort?.listen((data) {
      if (data is Map && data['type'] == 'play_video') {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => VideoPlayerScreen(
              video: data['video'],
              isUrl: data['isUrl'],
            ),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _receivePort?.close();
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
    setState(() => _isServiceRunning = running);
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
              _isServiceRunning ? 'Service Running' : 'Service Stopped',
              style: TextStyle(fontSize: 18),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: _isServiceRunning ? _stopService : _startService,
              child: Text(_isServiceRunning ? 'Stop Service' : 'Start Service'),
            ),
          ],
        ),
      ),
    );
  }
}

class VideoPlayerScreen extends StatefulWidget {
  final String video;
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
    WakelockPlus.enable();
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    if (widget.isUrl) {
      _controller = VideoPlayerController.networkUrl(Uri.parse(widget.video));
    } else {
      _controller = VideoPlayerController.file(File(widget.video));
    }
    await _controller.initialize();
    setState(() => _isInitialized = true);
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
          ? AspectRatio(
              aspectRatio: _controller.value.aspectRatio,
              child: VideoPlayer(_controller),
            )
          : Center(child: CircularProgressIndicator()),
    );
  }
}
