//import 'dart:ffi';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;
import 'package:wakelock/wakelock.dart';
import 'gradient_colors.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:battery_indicator/battery_indicator.dart';
import 'package:parallax_rain/parallax_rain.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;


void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SharedPreferences prefs = await SharedPreferences.getInstance();
  bool isStartupValuesSet = prefs.getBool('startupValuesSet') ?? false;
  if (!isStartupValuesSet) {
    // Set the default startup values
    prefs.setString('timezone1', 'Asia/Kolkata');
    prefs.setString('timezone2', 'America/New_York');
    prefs.setBool('parallaxVisible', false);
    prefs.setBool('startupValuesSet', true);
  }

  runApp(const ClockApp());
  tz.initializeTimeZones();
}

class ClockApp extends StatelessWidget {
  const ClockApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Work Clock',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        fontFamily: 'Alata',
      ),
      debugShowCheckedModeBanner: false,
      home: const ClockPage(),
    );
  }
}

class ClockPage extends StatefulWidget {
  const ClockPage({Key? key}) : super(key: key);

  @override
  _ClockPageState createState() => _ClockPageState();
}

class _ClockPageState extends State<ClockPage> with SingleTickerProviderStateMixin {
  late Timer _timer;
  late String _time;
  late String _currentDay;
  late String _timeZoneLocation;
  final Random _random = Random();
  late LinearGradient _currentBackgroundGradient;
  late String _remainingWorkDays = _remainingWorkingDays();
  bool isTimeUSVisible = false;
  String  _timeZoneTwo = 'America/New_York';
  String _timeZoneOne = 'Asia/Kolkata';
  List<String> timezones = tz.timeZoneDatabase.locations.keys
      .where((timezone) => timezone != 'UTC' && timezone != 'GMT')
      .toList();

  bool isParallaxRainVisible = false; // Initial visibility

  @override
  void initState() {
    super.initState();
    _readSharedPreferences();
    _currentBackgroundGradient = _getRandomBackgroundGradient();
    _currentDay = _getCurrentTime(_timeZoneOne,getDay: true);
    _time = _getCurrentTime(_timeZoneOne);
    _timeZoneLocation = _getCurrentTime(_timeZoneOne,getTimeZoneName: true);
    _timer = Timer.periodic(const Duration(seconds: 6), (timer)  {
      setState(() {
        if (isTimeUSVisible) {
          _time = _getCurrentTime(_timeZoneOne);
          _currentDay = _getCurrentTime(_timeZoneOne,getDay: true);
          _timeZoneLocation = _getCurrentTime(_timeZoneOne,getTimeZoneName: true);
        }else{
          _time = _getCurrentTimeUS(_timeZoneTwo);
          _currentDay = _getCurrentTimeUS(_timeZoneTwo,getDay: true);
          _timeZoneLocation = _getCurrentTimeUS(_timeZoneTwo,getTimeZoneName: true);
        }
        isTimeUSVisible = !isTimeUSVisible;
        _remainingWorkDays = _remainingWorkingDays();
      });
    });
    _startBackgroundTimer();
    Wakelock.enable();

  }


  void toggleParallaxRainVisibility() {
    setState(() {
      isParallaxRainVisible = !isParallaxRainVisible;
    });
  }
  Future<void> _readSharedPreferences() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      _timeZoneTwo = prefs.getString('timezone2') ?? 'America/New_York';
      _timeZoneOne = prefs.getString('timezone1')  ?? 'Asia/Kolkata';
      isParallaxRainVisible = prefs.getBool('parallaxVisible')!;
    });
  }
  Future<void> _writeSharedPreferences({String? timezone1, String? timezone2, bool? parallaxVisible }) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    if (timezone1 != null && timezone1.isNotEmpty) {
      await prefs.setString('timezone1', timezone1);
    }
    if (timezone2 != null && timezone2.isNotEmpty) {
      await prefs.setString('timezone2', timezone2);
    }
    await prefs.setBool('parallaxVisible', parallaxVisible!);
  }

  String _getCurrentTime(timeZoneOne,{bool getTimeZoneName = false,bool getDay = false}) {
    final kolkata = tz.getLocation(timeZoneOne);//'Asia/Kolkata'
    final now = tz.TZDateTime.now(kolkata);
    if(getTimeZoneName){
      //get Timezone name
      final timeZoneLocation = kolkata.name.split('/').last;
      String timeZoneLocationParsed = timeZoneLocation.replaceFirst("_", " ");
      return timeZoneLocationParsed;
    }else if(getDay){
      var day = now.day;
      var suffix = _getNumberSuffix(day);
      return '${DateFormat('EEEE, d').format(now)}$suffix';
    }else{
      return DateFormat('h:mm a').format(now);
    }
  }

  String _getCurrentTimeUS(timeZoneTwo,{bool getTimeZoneName = false,bool getDay = false}) {
    final newYork = tz.getLocation(timeZoneTwo);//'America/New_York'
    final now = tz.TZDateTime.now(newYork);
    if(getTimeZoneName){
      final timeZoneLocation = newYork.name.split('/').last;
      String timeZoneLocationParsed = timeZoneLocation.replaceFirst("_", " ");
      return timeZoneLocationParsed;
    }else if(getDay){
      var day = now.day;
      var suffix = _getNumberSuffix(day);
      return '${DateFormat('EEEE, d').format(now)}$suffix';
    }else{
      return DateFormat('h:mm a').format(now);
    }
  }

  String _getNumberSuffix(int number) {
    if (number >= 11 && number <= 13) {
      return 'th';
    }

    switch (number % 10) {
      case 1:
        return 'st';
      case 2:
        return 'nd';
      case 3:
        return 'rd';
      default:
        return 'th';
    }
  }

  LinearGradient _getRandomBackgroundGradient() {
    int index = _random.nextInt(PresetColors.backgroundGradients.length);
    return PresetColors.backgroundGradients[index];
  }

  void _updateBackground() {
    setState(() {
      _currentBackgroundGradient = _getRandomBackgroundGradient();
    });
  }
  String _remainingWorkingDays(){
    DateTime now = DateTime.now();
    int totalDaysInMonth = DateTime(now.year, now.month + 1, 0).day;

    int remainingWorkingDays = 0;
    int remainingNonWorkingDays = 0;

    for (int i = now.day + 1; i <= totalDaysInMonth; i++) {
      DateTime date = DateTime(now.year, now.month, i);
      if (date.weekday >= DateTime.monday && date.weekday <= DateTime.friday) {
        remainingWorkingDays++;
      } else {
        remainingNonWorkingDays++;
      }
    }

    return '$remainingWorkingDays | $remainingNonWorkingDays';
  }
  void _startBackgroundTimer() {
    Timer.periodic(const Duration(seconds: 6), (timer) {
      _updateBackground();
    });
  }

  @override
  void dispose() {

    super.dispose();
    _timer.cancel();
  }

  Widget buildTimeWidget(String time) {
    return FractionallySizedBox(
      heightFactor: 1.68,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: 1),
        duration: const Duration(seconds: 6),
        curve: Curves.slowMiddle,
        builder: (context, value, child) {
          return ShaderMask(
            shaderCallback: (Rect bounds) {
              return _currentBackgroundGradient.createShader(bounds);
            },
            child: Opacity(
              opacity: value,
              child: child,
            ),
          );
        },
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          transitionBuilder:
              (Widget child, Animation<double> animation) {
            return FadeTransition(
              opacity: animation,
              child: child,
            );
          },
          child: Text(
            time,
            key: ValueKey<String>(time),
            style: TextStyle(
              fontSize: MediaQuery.of(context).size.width * 0.20,
              fontWeight: FontWeight.bold,
              fontFamily: 'Alata',
              color: Colors.white.withOpacity(1),
              shadows: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.5),
                  spreadRadius: 5,
                  blurRadius: 10,
                  offset: const Offset(2, 0),
                ),
              ],
            ),
          ),
        ),

      ),
    );

  }
  Widget buildCurrentDayWidget(String currentDay) {
    return Stack(
      children: [
        FractionallySizedBox(
          heightFactor: 0.6,
          widthFactor: 1,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: const Duration(seconds: 6),
            curve: Curves.slowMiddle,
            builder: (context, value, child) {
              return ShaderMask(
                shaderCallback: (Rect bounds) {
                  return _currentBackgroundGradient.createShader(bounds);
                },
                child: Opacity(
                  opacity: value,
                  child: child,
                ),
              );
            },
            child: Align(
              alignment: Alignment.center,
              child: Text(
                currentDay,
                style: TextStyle(
                  fontSize: MediaQuery.of(context).size.width * 0.06,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Alata',
                  color: Colors.white.withOpacity(1),
                  shadows: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.5),
                      spreadRadius: 2,
                      blurRadius: 10,
                      offset: const Offset(1, 1),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.center,
          widthFactor: 0.7,
          heightFactor: 2.2,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                flex: 0,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child : defaultTargetPlatform == TargetPlatform.android
                      ? BatteryIndicator(
                    style: BatteryIndicatorStyle.values[1],
                    colorful: false,
                    showPercentNum: false,
                    mainColor: _currentBackgroundGradient.colors.last,
                    size: 44,
                    ratio: 1.5,
                    showPercentSlide: true,
                    percentNumSize: 50,
                  )
                      : Container(),
                  // child: BatteryIndicator(
                  //   style: BatteryIndicatorStyle.values[1],
                  //   colorful: false,
                  //   showPercentNum: false,
                  //   mainColor: _currentBackgroundGradient.colors.last,
                  //   size: 44,
                  //   ratio: 1.5,
                  //   showPercentSlide: true,
                  //   percentNumSize: 50,
                  // ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
  //test
  void showDropdownMenu(BuildContext context) {

    final RenderBox button = context.findRenderObject() as RenderBox;
    final RenderBox overlay = Overlay.of(context).context.findRenderObject() as RenderBox;

    RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );

    final List<PopupMenuEntry<String>> menuItems = [
      PopupMenuItem<String>(
        enabled: false,
        child: Container(
          key: ValueKey<String>("${_timeZoneTwo}xx"),
          padding: const EdgeInsets.symmetric(vertical: 30.0, horizontal: 50.0),
          decoration: BoxDecoration(
            gradient: _currentBackgroundGradient,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text(
                'Select Primary Timezone',
                style: TextStyle(
                  fontSize: 20.0,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 20.0),
              DropdownButton<String>(
                key: ValueKey<String>(_timeZoneOne),
                isExpanded: true,
                value: _timeZoneOne,
                dropdownColor: _currentBackgroundGradient.colors.first,
                hint: const Text('Select Primary Timezone'),
                items: timezones.map((timezone) {
                  return DropdownMenuItem<String>(
                    value: timezone,
                    child: Text(
                      timezone,
                      style: const TextStyle(
                        color: Colors.white,
                      ),
                    ),
                  );
                }).toList(),
                onChanged: (String? value) {
                  setState(() {
                    _timeZoneOne = value!;
                  });
                  if (value != null) {
                    _writeSharedPreferences(timezone1: value);
                  }
                  Navigator.of(context).pop();
                },
              ),
              const SizedBox(height: 20.0),
              const Text(
                'Select Secondary Timezone',
                style: TextStyle(
                  fontSize: 20.0,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 20.0),
              DropdownButton<String>(
                key: ValueKey<String>(_timeZoneTwo),
                isExpanded: true,
                value: _timeZoneTwo,
                dropdownColor: _currentBackgroundGradient.colors.last,
                focusColor: Colors.cyan,
                enableFeedback: true,
                hint: const Text('Select Second Timezone'),
                items: timezones.map((timezone) {
                  return DropdownMenuItem<String>(
                    value: timezone,
                    child: Text(
                      timezone,
                      style: const TextStyle(
                        color: Colors.white,
                      ),
                    ),
                  );
                }).toList(),
                onChanged: (String? value) {
                  setState(() {
                    _timeZoneTwo = value!;
                  });
                  if (value != null) {
                    _writeSharedPreferences(timezone2: value);
                  }
                  Navigator.of(context).pop();
                },
              ),
            ],
          ),
        ),
      ),
    ];

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16.0),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16.0),
            child: Container(
              decoration: BoxDecoration(
                gradient: _currentBackgroundGradient,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: menuItems,
                ),
              ),
            ),
          ),
        );
      },
    ).then((value) {
      if (value != null) {
      }
    }).whenComplete(() {
      setState(() {});
    });
  }



  //test
  Widget buildTimeZoneWidget(String location,String workDays) {
    return FractionallySizedBox(
      heightFactor: 0.4,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: 1),
        duration: const Duration(seconds: 6),
        curve: Curves.slowMiddle,
        builder: (context, value, child) {
          return ShaderMask(
            shaderCallback: (Rect bounds) {
              return _currentBackgroundGradient.createShader(bounds);
            },
            child: Opacity(
              opacity: value,
              child: child,
            ),
          );
        },
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap : () {
                  showDropdownMenu(context);
                },
                child: Center(
                  child: Text(
                    location,
                    style: TextStyle(
                      fontSize: MediaQuery.of(context).size.width * 0.05,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'Alata',
                      color: Colors.white.withOpacity(1),
                      shadows: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.5),
                          spreadRadius: 2,
                          blurRadius: 10,
                          offset: const Offset(1, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child:Row(
                children: [
                  Expanded(
                      child: Center(
                        child:GestureDetector(
                            onTap: () {
                              // Handle the click event here
                              Fluttertoast.showToast(
                                msg: "You have ${workDays.split('|')[0]}days of work and${workDays.split('|')[1]} days of rest this month",
                                toastLength: Toast.LENGTH_LONG,
                                gravity: ToastGravity.BOTTOM,
                                backgroundColor: _currentBackgroundGradient.colors.first.withOpacity(0.7),
                                textColor: Colors.white,
                                fontSize: 40.0,
                              );
                            },
                            child: Text(
                              workDays.replaceAll('|', ''),
                              style: TextStyle(
                                fontSize: MediaQuery.of(context).size.width * 0.05,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'Alata',
                                color: Colors.white.withOpacity(1),
                                shadows: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.5),
                                    spreadRadius: 2,
                                    blurRadius: 10,
                                    offset: const Offset(1, 1),
                                  ),
                                ],
                              ),
                            )
                        ),
                      )
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  @override
  Widget build(BuildContext context) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    final mainWidgetTree = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Expanded(
          child: Center(
            child: buildCurrentDayWidget(_currentDay),
          ),
        ),
        Expanded(
          child: Center(
            child: buildTimeWidget(_time),
          ),
        ),
        Expanded(
          child: Center(
            child: buildTimeZoneWidget(
              _timeZoneLocation,
              _remainingWorkDays,
            ),
          ),
        ),
      ],
    );
    Widget bodyWidget;
    if (isParallaxRainVisible) {
      bodyWidget = ParallaxRain(
        dropColors: const [
          Colors.red,
          Colors.green,
          Colors.blue,
          Colors.yellow,
          Colors.brown,
          Colors.blueGrey,
          Colors.purpleAccent,
          Colors.cyanAccent,
        ],
        dropWidth: 1,
        dropHeight: 50,
        trail: true,
        numberOfDrops: 200,
        numberOfLayers: 3,
        dropFallSpeed: 1,
        child: mainWidgetTree,
      );
    } else {

      bodyWidget = AnimatedContainer(
        duration: const Duration(seconds: 6),
        decoration: BoxDecoration(
          gradient: _currentBackgroundGradient,
        ),
        child: mainWidgetTree,
      );
    }
    Color scaffoldBackgroundColor = isParallaxRainVisible ? Colors.black : Colors.white;
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          toggleParallaxRainVisibility();
          if(isParallaxRainVisible){
            _writeSharedPreferences(parallaxVisible: true);
          }else{
            _writeSharedPreferences(parallaxVisible: false);
          }

        },
        backgroundColor: _currentBackgroundGradient.colors.last.withOpacity(0.3),
        elevation: 0.0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(100.0),
        ),
        child: Icon(
          Icons.landscape,
          color: _currentBackgroundGradient.colors.first.withOpacity(0.3),
        ),
      ),
      backgroundColor: scaffoldBackgroundColor,
      body: bodyWidget,
    );
  }
}
