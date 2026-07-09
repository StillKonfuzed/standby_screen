import 'dart:async';
import 'dart:math';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:intl/intl.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:parallax_rain/parallax_rain.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:wakelock_plus/wakelock_plus.dart';

import 'gradient_colors.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize timezones before everything else
  tz.initializeTimeZones();

  final prefs = await SharedPreferences.getInstance();
  final bool isStartupValuesSet = prefs.getBool('startupValuesSet') ?? false;
  if (!isStartupValuesSet) {
    // Set the default startup values
    await prefs.setString('timezone1', 'Asia/Kolkata');
    await prefs.setString('timezone2', 'America/New_York');
    await prefs.setBool('parallaxVisible', false);
    await prefs.setBool('startupValuesSet', true);
  }

  runApp(const ClockApp());
}

class _VisualizerPainter extends CustomPainter {
  final double amplitude;
  final LinearGradient gradient;
  final List<double> barHeights;
  final Random random;

  _VisualizerPainter({
    required this.amplitude,
    required this.gradient,
    required this.barHeights,
    required this.random,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader = gradient.createShader(Offset.zero & size)
      ..style = PaintingStyle.fill;

    final double width = size.width;
    final double height = size.height;
    final int count = barHeights.length;
    final double barWidth = width / count;
    
    for (int i = 0; i < count; i++) {
      // Increase sensitivity and height multiplier
      // Using 1.3 multiplier to reach high but not overlap too much
      final double boostedAmplitude = amplitude * 1.3;
      final double targetHeight = (boostedAmplitude * height) * (0.3 + random.nextDouble() * 0.7);
      
      // Dual-stage smoothing for a more fluid, high-end feel
      // Falling bars move slower than rising bars to create "momentum"
      // Adjusted falling factor (0.3) for faster retraction when silent
      double smoothingFactor = (targetHeight > barHeights[i]) ? 0.4 : 0.3;
      barHeights[i] = barHeights[i] * (1 - smoothingFactor) + targetHeight * smoothingFactor;

      final double currentBarHeight = barHeights[i];
      if (currentBarHeight <= 0) continue;

      final double x = i * barWidth;
      final double clampedHeight = currentBarHeight > height ? height : currentBarHeight;
      final double y = height - clampedHeight;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x + 2, y, barWidth - 4, clampedHeight),
          const Radius.circular(4),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _VisualizerPainter oldDelegate) {
    // Optimization: Always repaint while there's activity or bars are still retracting
    // To ensure bars reach zero smoothly, we check if any bar still has height
    return amplitude > 0 || barHeights.any((h) => h > 0.1);
  }
}

class ClockApp extends StatelessWidget {
  const ClockApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Work Clock',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        fontFamily: 'Alata',
        useMaterial3: true,
      ),
      debugShowCheckedModeBanner: false,
      home: const ClockPage(),
    );
  }
}

class ClockPage extends StatefulWidget {
  const ClockPage({super.key});

  @override
  State<ClockPage> createState() => _ClockPageState();
}

class _ClockPageState extends State<ClockPage> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  Timer? _clockTimer;
  Timer? _backgroundTimer;

  final Battery _battery = Battery();
  final ValueNotifier<int> _batteryLevelNotifier = ValueNotifier<int>(100);
  final ValueNotifier<BatteryState> _batteryStateNotifier = ValueNotifier<BatteryState>(BatteryState.unknown);
  StreamSubscription<BatteryState>? _batterySubscription;

  final ValueNotifier<String> _timeNotifier = ValueNotifier<String>('');
  final ValueNotifier<String> _currentDayNotifier = ValueNotifier<String>('');
  final ValueNotifier<String> _timeZoneLocationNotifier = ValueNotifier<String>('');
  final ValueNotifier<LinearGradient> _currentBackgroundGradientNotifier = ValueNotifier<LinearGradient>(const LinearGradient(colors: [Colors.blue, Colors.purple]));
  final ValueNotifier<String> _remainingWorkDaysNotifier = ValueNotifier<String>('');

  bool _isPrimaryTimezoneVisible = true;
  String _timeZoneOne = 'Asia/Kolkata';
  String _timeZoneTwo = 'America/New_York';
  final ValueNotifier<bool> _isParallaxRainVisibleNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _isManualBlackAndWhiteNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _isAuroraPulseVisibleNotifier = ValueNotifier<bool>(false);

  // Aurora Pulse Logic
  NoiseMeter? _noiseMeter;
  StreamSubscription<NoiseReading>? _noiseSubscription;
  final ValueNotifier<double> _amplitudeNotifier = ValueNotifier<double>(0.0);
  
  // Visualizer bar heights for smoothing
  final List<double> _barHeights = List.generate(30, (_) => 0.0);
  Ticker? _ticker;

  final Random _random = Random();
  late final List<String> _availableTimezones;
  late final Listenable _environmentListenable;

  // Cached objects for efficiency
  final DateFormat _timeFormatter = DateFormat('h:mm a');
  final DateFormat _dayFormatter = DateFormat('EEEE, d');
  int _lastCalculatedDay = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    _environmentListenable = Listenable.merge([
      _batteryStateNotifier,
      _isManualBlackAndWhiteNotifier,
      _isAuroraPulseVisibleNotifier,
    ]);

    _availableTimezones = tz.timeZoneDatabase.locations.keys
        .where((timezone) => timezone != 'UTC' && timezone != 'GMT')
        .toList();

    _currentBackgroundGradientNotifier.value = _getRandomBackgroundGradient();
    
    // Set initial values
    _updateTimeDisplay();
    _checkAndCalculateWorkDays();

    _loadSettings();
    _startTimers();
    _initBattery();
    
    _ticker = createTicker((elapsed) {
      if (_isAuroraPulseVisibleNotifier.value) {
        // Force a rebuild for the visualizer to allow bar physics to finish
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        _amplitudeNotifier.notifyListeners();
      }
    });
    _ticker!.start();
    
    WakelockPlus.enable();
    
    // System configuration
    _setSystemUI();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  void _setSystemUI() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _setSystemUI();
      _updateTimeDisplay();
      _checkAndCalculateWorkDays();
    }
  }

  void _checkAndCalculateWorkDays() {
    final now = DateTime.now();
    if (now.day != _lastCalculatedDay) {
      _lastCalculatedDay = now.day;
      _remainingWorkDaysNotifier.value = _calculateRemainingWorkingDays();
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      _timeZoneOne = prefs.getString('timezone1') ?? 'Asia/Kolkata';
      _timeZoneTwo = prefs.getString('timezone2') ?? 'America/New_York';
      _isParallaxRainVisibleNotifier.value = prefs.getBool('parallaxVisible') ?? false;
      _isManualBlackAndWhiteNotifier.value = prefs.getBool('manualBlackAndWhite') ?? false;
      _isAuroraPulseVisibleNotifier.value = prefs.getBool('auroraPulseVisible') ?? false;
      _updateTimeDisplay();
    }
  }

  Future<void> _updateSettings({String? timezone1, String? timezone2, bool? parallaxVisible, bool? manualBlackAndWhite, bool? auroraPulseVisible}) async {
    final prefs = await SharedPreferences.getInstance();
    if (timezone1 != null) {
      _timeZoneOne = timezone1;
      await prefs.setString('timezone1', timezone1);
    }
    if (timezone2 != null) {
      _timeZoneTwo = timezone2;
      await prefs.setString('timezone2', timezone2);
    }
    if (parallaxVisible != null) {
      _isParallaxRainVisibleNotifier.value = parallaxVisible;
      await prefs.setBool('parallaxVisible', parallaxVisible);
    }
    if (manualBlackAndWhite != null) {
      _isManualBlackAndWhiteNotifier.value = manualBlackAndWhite;
      await prefs.setBool('manualBlackAndWhite', manualBlackAndWhite);
    }
    if (auroraPulseVisible != null) {
      _isAuroraPulseVisibleNotifier.value = auroraPulseVisible;
      await prefs.setBool('auroraPulseVisible', auroraPulseVisible);
      _handleAuroraPulseToggle(auroraPulseVisible);
    }
    if (mounted) {
      _updateTimeDisplay();
    }
  }

  void _handleAuroraPulseToggle(bool enabled) {
    if (enabled && _isCharging) {
      _startAuroraPulse();
    } else {
      _stopAuroraPulse();
    }
  }

  bool get _isCharging {
    return _batteryStateNotifier.value == BatteryState.charging || _batteryStateNotifier.value == BatteryState.full;
  }

  void _startAuroraPulse() async {
    final status = await Permission.microphone.status;
    if (status.isGranted) {
      _noiseMeter ??= NoiseMeter();
      _noiseSubscription?.cancel();
      _noiseSubscription = _noiseMeter!.noise.listen((reading) {
        // More sensitive mapping: decibel 30-100 -> 0.0-1.0
        // We'll also add a slight boost to the maxDecibel reading
        double normalized = (reading.maxDecibel - 35) / 60;
        _amplitudeNotifier.value = normalized.clamp(0.0, 1.0);
      });
    }
  }

  Future<void> _requestMicPermission() async {
    final status = await Permission.microphone.status;
    if (status.isGranted) return;

    if (mounted) {
      final bool? proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Colors.grey[900],
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.mic, color: Colors.blueAccent),
              SizedBox(width: 10),
              Text('Microphone Access', style: TextStyle(color: Colors.white)),
            ],
          ),
          content: const Text(
            'The Music Visualizer needs microphone access to detect ambient sound and animate the bars. \n\nNo audio is recorded, stored, or sent anywhere. It is processed entirely on your device for visualization only. Also this app has no intenet access to upload any data anywhere for double safety.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Allow Access'),
            ),
          ],
        ),
      );

      if (proceed == true) {
        await Permission.microphone.request();
        _handleAuroraPulseToggle(_isAuroraPulseVisibleNotifier.value);
      } else {
        // Fall back to gradients if permission denied
        _updateSettings(auroraPulseVisible: false);
      }
    }
  }

  void _stopAuroraPulse() {
    _noiseSubscription?.cancel();
    _noiseSubscription = null;
    _amplitudeNotifier.value = 0.0;
  }

  Widget _buildVisualizerBars(double amplitude, LinearGradient gradient) {
    return CustomPaint(
      size: Size.infinite,
      painter: _VisualizerPainter(
        amplitude: amplitude,
        gradient: gradient,
        barHeights: _barHeights,
        random: _random,
      ),
    );
  }

  void _startTimers() {
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        final now = DateTime.now();
        // Toggle timezone every 6 seconds
        if (now.second % 6 == 0) {
          _isPrimaryTimezoneVisible = !_isPrimaryTimezoneVisible;
          _updateTimeDisplay();
          _checkAndCalculateWorkDays();
        } else {
          _updateTimeDisplay();
        }
      }
    });

    _backgroundTimer = Timer.periodic(const Duration(seconds: 6), (timer) {
      if (mounted) {
        // Only update background if not in battery saver mode (unplugged)
        final bool isUnplugged = _batteryStateNotifier.value != BatteryState.charging && _batteryStateNotifier.value != BatteryState.full;
        if (!isUnplugged && !_isManualBlackAndWhiteNotifier.value) {
          _currentBackgroundGradientNotifier.value = _getRandomBackgroundGradient();
        }
      }
    });
  }

  void _updateTimeDisplay() {
    final activeTimezone = _isPrimaryTimezoneVisible ? _timeZoneOne : _timeZoneTwo;
    final location = tz.getLocation(activeTimezone);
    final now = tz.TZDateTime.now(location);

    _timeNotifier.value = _timeFormatter.format(now);
    
    final day = now.day;
    final suffix = _getNumberSuffix(day);
    _currentDayNotifier.value = '${_dayFormatter.format(now)}$suffix';
    
    _timeZoneLocationNotifier.value = location.name.split('/').last.replaceAll('_', ' ');
  }

  String _getNumberSuffix(int number) {
    if (number >= 11 && number <= 13) return 'th';
    switch (number % 10) {
      case 1: return 'st';
      case 2: return 'nd';
      case 3: return 'rd';
      default: return 'th';
    }
  }

  LinearGradient _getRandomBackgroundGradient() {
    if (PresetColors.backgroundGradients.isEmpty) {
      return const LinearGradient(colors: [Colors.blue, Colors.purple]);
    }
    return PresetColors.backgroundGradients[_random.nextInt(PresetColors.backgroundGradients.length)];
  }

  String _calculateRemainingWorkingDays() {
    final now = DateTime.now();
    final lastDayOfMonth = DateTime(now.year, now.month + 1, 0).day;

    int workingDays = 0;
    int restDays = 0;

    for (int i = now.day + 1; i <= lastDayOfMonth; i++) {
      final date = DateTime(now.year, now.month, i);
      if (date.weekday >= DateTime.monday && date.weekday <= DateTime.friday) {
        workingDays++;
      } else {
        restDays++;
      }
    }
    return '$workingDays | $restDays';
  }

  void _initBattery() async {
    final level = await _battery.batteryLevel;
    _batterySubscription = _battery.onBatteryStateChanged.listen((state) {
      if (mounted) {
        _batteryStateNotifier.value = state;
        // Automatically stop aurora pulse if unplugged
        if (!_isCharging) {
          _stopAuroraPulse();
        } else if (_isAuroraPulseVisibleNotifier.value) {
          _startAuroraPulse();
        }
      }
    });

    if (mounted) {
      _batteryLevelNotifier.value = level;
    }

    // Update battery level periodically
    Timer.periodic(const Duration(minutes: 1), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final level = await _battery.batteryLevel;
      _batteryLevelNotifier.value = level;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopAuroraPulse();
    _ticker?.dispose();
    _clockTimer?.cancel();
    _backgroundTimer?.cancel();
    _batterySubscription?.cancel();
    _batteryLevelNotifier.dispose();
    _batteryStateNotifier.dispose();
    _timeNotifier.dispose();
    _currentDayNotifier.dispose();
    _timeZoneLocationNotifier.dispose();
    _currentBackgroundGradientNotifier.dispose();
    _remainingWorkDaysNotifier.dispose();
    _isParallaxRainVisibleNotifier.dispose();
    _isManualBlackAndWhiteNotifier.dispose();
    _isAuroraPulseVisibleNotifier.dispose();
    _amplitudeNotifier.dispose();
    super.dispose();
  }

  Widget _buildTimeWidget() {
    return AnimatedBuilder(
      animation: _environmentListenable,
      builder: (context, _) {
        final bool isUnplugged = _batteryStateNotifier.value != BatteryState.charging && _batteryStateNotifier.value != BatteryState.full;
        final bool isBatterySaver = isUnplugged || _isManualBlackAndWhiteNotifier.value;
        final bool isAuroraVisible = _isAuroraPulseVisibleNotifier.value;

        return ValueListenableBuilder<String>(
          valueListenable: _timeNotifier,
          builder: (context, time, _) {
            return ValueListenableBuilder<LinearGradient>(
              valueListenable: _currentBackgroundGradientNotifier,
              builder: (context, gradient, _) {
                return TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 500),
                  builder: (context, value, child) {
                    if (isBatterySaver || isAuroraVisible) {
                      return Opacity(opacity: value, child: child);
                    }
                    return ShaderMask(
                      shaderCallback: (bounds) => gradient.createShader(bounds),
                      child: Opacity(opacity: value, child: child),
                    );
                  },
                  child: AnimatedSwitcher(
                    duration: isBatterySaver ? Duration.zero : const Duration(milliseconds: 500),
                    transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: Text(
                        time,
                        key: ValueKey<String>(time),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 400,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          letterSpacing: -5,
                          height: 1.0,
                          shadows: [
                            Shadow(
                              color: Colors.black,
                              blurRadius: 15,
                              offset: Offset(4, 4),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildCurrentDayWidget() {
    return AnimatedBuilder(
      animation: _environmentListenable,
      builder: (context, _) {
        final bool isUnplugged = _batteryStateNotifier.value != BatteryState.charging && _batteryStateNotifier.value != BatteryState.full;
        final bool isBatterySaver = isUnplugged || _isManualBlackAndWhiteNotifier.value;
        final bool isAuroraVisible = _isAuroraPulseVisibleNotifier.value;

        return ValueListenableBuilder<String>(
          valueListenable: _currentDayNotifier,
          builder: (context, currentDay, _) {
            final text = Text(
              currentDay,
              style: TextStyle(
                fontSize: MediaQuery.of(context).size.width * 0.05,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                shadows: const [
                  Shadow(
                    color: Colors.black54,
                    blurRadius: 8,
                    offset: Offset(1, 1),
                  ),
                ],
              ),
            );

            if (isBatterySaver || isAuroraVisible) return text;

            return ValueListenableBuilder<LinearGradient>(
              valueListenable: _currentBackgroundGradientNotifier,
              builder: (context, gradient, _) {
                return ShaderMask(
                  shaderCallback: (bounds) => gradient.createShader(bounds),
                  child: text,
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildCustomBatteryIndicator() {
    return ValueListenableBuilder<BatteryState>(
      valueListenable: _batteryStateNotifier,
      builder: (context, batteryState, _) {
        final bool isCharging = batteryState == BatteryState.charging;
        return ValueListenableBuilder<int>(
          valueListenable: _batteryLevelNotifier,
          builder: (context, batteryLevel, _) {
            return ValueListenableBuilder<LinearGradient>(
              valueListenable: _currentBackgroundGradientNotifier,
              builder: (context, gradient, _) {
                final color = gradient.colors.last.withValues(alpha: 0.8);
                return RepaintBoundary(
                  child: Container(
                    width: 95,
                    height: 45,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      border: Border.all(color: color, width: 3.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Stack(
                      children: [
                        FractionallySizedBox(
                          widthFactor: batteryLevel / 100.0,
                          child: Container(
                            decoration: BoxDecoration( 
                              color: color,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                        Center(
                          child: isCharging
                              ? const Icon(
                                  Icons.bolt,
                                  size: 36,
                                  color: Colors.white,
                                )
                              : Text(
                                  '$batteryLevel%',
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return ValueListenableBuilder<LinearGradient>(
          valueListenable: _currentBackgroundGradientNotifier,
          builder: (context, gradient, _) {
            return AlertDialog(
              backgroundColor: Colors.transparent,
              contentPadding: EdgeInsets.zero,
              insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
              content: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  gradient: gradient,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Clock Settings',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    const SizedBox(height: 24),
                    _buildTimezoneDropdown('Primary Timezone', _timeZoneOne, (val) {
                      if (val != null) _updateSettings(timezone1: val);
                    }),
                    const SizedBox(height: 20),
                    _buildTimezoneDropdown('Secondary Timezone', _timeZoneTwo, (val) {
                      if (val != null) _updateSettings(timezone2: val);
                    }),
                    const SizedBox(height: 24),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close', style: TextStyle(color: Colors.white, fontSize: 16)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTimezoneDropdown(String label, String value, ValueChanged<String?> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)),
        DropdownButton<String>(
          isExpanded: true,
          value: value,
          dropdownColor: _currentBackgroundGradientNotifier.value.colors.first,
          iconEnabledColor: Colors.white,
          underline: Container(height: 1, color: Colors.white30),
          items: _availableTimezones.map((tz) {
            return DropdownMenuItem(value: tz, child: Text(tz, style: const TextStyle(color: Colors.white)));
          }).toList(),
          onChanged: (val) {
            onChanged(val);
            Navigator.pop(context);
          },
        ),
      ],
    );
  }

  Widget _buildFooterWidget() {
    return AnimatedBuilder(
      animation: _environmentListenable,
      builder: (context, _) {
        final bool isUnplugged = _batteryStateNotifier.value != BatteryState.charging && _batteryStateNotifier.value != BatteryState.full;
        final bool isBatterySaver = isUnplugged || _isManualBlackAndWhiteNotifier.value;
        final bool isAuroraVisible = _isAuroraPulseVisibleNotifier.value;
        final bool useSimpleText = isBatterySaver || isAuroraVisible;

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ValueListenableBuilder<String>(
              valueListenable: _timeZoneLocationNotifier,
              builder: (context, location, _) {
                return GestureDetector(
                  onTap: _showSettingsDialog,
                  child: _buildStyledText(location, fontSizeFactor: 0.04, useSimpleText: useSimpleText),
                );
              },
            ),
            ValueListenableBuilder<String>(
              valueListenable: _remainingWorkDaysNotifier,
              builder: (context, workDays, _) {
                return GestureDetector(
                  onTap: () {
                    final parts = workDays.split(' | ');
                    ScaffoldMessenger.of(context).clearSnackBars();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          "Work: ${parts[0]} days | Rest: ${parts[1]} days remaining",
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        backgroundColor: _currentBackgroundGradientNotifier.value.colors.first.withValues(alpha: 0.9),
                        behavior: SnackBarBehavior.floating,
                        duration: const Duration(seconds: 4),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        margin: EdgeInsets.symmetric(
                          horizontal: MediaQuery.of(context).size.width * 0.2,
                          vertical: 20,
                        ),
                      ),
                    );
                  },
                  child: _buildStyledText(workDays.replaceAll(' | ', ' '), fontSizeFactor: 0.04, useSimpleText: useSimpleText),
                );
              },
            ),
          ],
        );
      },
    );
  }

  Widget _buildStyledText(String text, {required double fontSizeFactor, bool useSimpleText = false}) {
    final textWidget = Text(
      text,
      style: TextStyle(
        fontSize: MediaQuery.of(context).size.width * fontSizeFactor,
        fontWeight: FontWeight.bold,
        color: Colors.white,
        shadows: const [
          Shadow(
            color: Colors.black54,
            blurRadius: 8,
            offset: Offset(1, 1),
          ),
        ],
      ),
    );

    if (useSimpleText) return textWidget;

    return ValueListenableBuilder<LinearGradient>(
      valueListenable: _currentBackgroundGradientNotifier,
      builder: (context, gradient, _) {
        return ShaderMask(
          shaderCallback: (bounds) => gradient.createShader(bounds),
          child: textWidget,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final mainContent = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 10), 
          child: _buildCurrentDayWidget(),
        ),
        Expanded(
          flex: 8,
          child: Center(child: _buildTimeWidget()),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _buildFooterWidget(),
        ),
      ],
    );

    final bodyContent = Stack(
      children: [
        SafeArea(
          left: true,
          right: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: mainContent,
          ),
        ),
        if (defaultTargetPlatform == TargetPlatform.android)
          Positioned(
            top: 20,
            right: 20, 
            child: _buildCustomBatteryIndicator(),
          ),
      ],
    );

    return Scaffold(
      body: ValueListenableBuilder<BatteryState>(
        valueListenable: _batteryStateNotifier,
        builder: (context, batteryState, _) {
          return ValueListenableBuilder<bool>(
            valueListenable: _isManualBlackAndWhiteNotifier,
            builder: (context, isManualBW, _) {
              final bool isUnplugged = batteryState != BatteryState.charging && batteryState != BatteryState.full;
              final bool isBatterySaver = isUnplugged || isManualBW;

              return ValueListenableBuilder<bool>(
                valueListenable: _isParallaxRainVisibleNotifier,
                builder: (context, isParallaxVisible, _) {
                  return ValueListenableBuilder<bool>(
                    valueListenable: _isAuroraPulseVisibleNotifier,
                    builder: (context, isAuroraVisible, _) {
                      return Container(
                        color: (isBatterySaver || isParallaxVisible) ? Colors.black : Colors.white,
                        child: AnimatedSwitcher(
                          duration: isBatterySaver ? Duration.zero : const Duration(seconds: 1),
                          child: (isParallaxVisible && !isBatterySaver)
                              ? RepaintBoundary(
                                  key: const ValueKey('parallax_layer'),
                                  child: ParallaxRain(
                                    key: const ValueKey('parallax'),
                                    dropColors: const [
                                      Colors.red, Colors.green, Colors.blue, Colors.yellow,
                                      Colors.brown, Colors.blueGrey, Colors.purpleAccent, Colors.cyanAccent,
                                    ],
                                    dropWidth: 1,
                                    dropHeight: 50,
                                    numberOfDrops: 200,
                                    child: bodyContent,
                                  ),
                                )
                              : ValueListenableBuilder<LinearGradient>(
                                  valueListenable: _currentBackgroundGradientNotifier,
                                  builder: (context, gradient, _) {
                                    return RepaintBoundary(
                                      key: const ValueKey('gradient_layer'),
                                      child: ValueListenableBuilder<double>(
                                        valueListenable: _amplitudeNotifier,
                                        builder: (context, amplitude, child) {
                                          final isActuallyAurora = isAuroraVisible && !isBatterySaver;
                                          return AnimatedContainer(
                                            key: const ValueKey('gradient'),
                                            duration: (isActuallyAurora) 
                                                ? const Duration(milliseconds: 100) 
                                                : (isBatterySaver ? Duration.zero : const Duration(seconds: 6)),
                                            decoration: BoxDecoration(
                                              color: (isBatterySaver || isActuallyAurora) ? Colors.black : null,
                                              gradient: (isBatterySaver || isActuallyAurora) ? null : gradient,
                                            ),
                                            child: Stack(
                                              children: [
                                                if (isActuallyAurora)
                                                  _buildVisualizerBars(amplitude, gradient),
                                                child!,
                                              ],
                                            ),
                                          );
                                        },
                                        child: bodyContent,
                                      ),
                                    );
                                  },
                                ),
                        ),
                      );
                    },
                  );
                },
              );
            },
          );
        },
      ),
      floatingActionButton: ValueListenableBuilder<BatteryState>(
        valueListenable: _batteryStateNotifier,
        builder: (context, batteryState, _) {
          final bool isUnplugged = batteryState != BatteryState.charging && batteryState != BatteryState.full;
          // FAB is now always visible, but we can style it differently if unplugged if desired
          // For now, keeping it consistent as per user request to "keep it active"

          return ValueListenableBuilder<bool>(
            valueListenable: _isManualBlackAndWhiteNotifier,
            builder: (context, isManualBW, _) {
              return ValueListenableBuilder<bool>(
                valueListenable: _isParallaxRainVisibleNotifier,
                builder: (context, isParallaxVisible, _) {
                  return ValueListenableBuilder<bool>(
                    valueListenable: _isAuroraPulseVisibleNotifier,
                    builder: (context, isAuroraVisible, _) {
                      return ValueListenableBuilder<LinearGradient>(
                        valueListenable: _currentBackgroundGradientNotifier,
                        builder: (context, gradient, _) {
                          final bool isBatterySaver = isManualBW;
                          return FloatingActionButton(
                            onPressed: () {
                              if (!isParallaxVisible && !isManualBW && !isAuroraVisible) {
                                _updateSettings(parallaxVisible: true, manualBlackAndWhite: false, auroraPulseVisible: false);
                              } else if (isParallaxVisible) {
                                _updateSettings(parallaxVisible: false, manualBlackAndWhite: false, auroraPulseVisible: true);
                                _requestMicPermission();
                              } else if (isAuroraVisible) {
                                _updateSettings(parallaxVisible: false, manualBlackAndWhite: true, auroraPulseVisible: false);
                              } else {
                                _updateSettings(parallaxVisible: false, manualBlackAndWhite: false, auroraPulseVisible: false);
                              }
                            },
                            backgroundColor: isBatterySaver
                                ? Colors.grey.withValues(alpha: 0.3)
                                : gradient.colors.last.withValues(alpha: 0.3),
                            elevation: 0,
                            shape: const CircleBorder(),
                            child: Icon(
                              isParallaxVisible 
                                  ? Icons.nightlight_round 
                                  : (isAuroraVisible 
                                      ? Icons.audiotrack 
                                      : (isManualBW ? Icons.color_lens : Icons.landscape)),
                              color: isBatterySaver
                                  ? Colors.white.withValues(alpha: 0.5)
                                  : gradient.colors.first.withValues(alpha: 0.5),
                            ),
                          );
                        },
                      );
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
