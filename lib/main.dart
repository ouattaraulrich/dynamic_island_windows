import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

// ---------------------------------------------------------------------------
// Design
//   Nuit     #03050C  la pilule
//   Texte    #F2F4F8  heure, texte principal
//   Gris     #8A93A6  texte secondaire
//   Azur     #19B8FF  accent (onglet actif, progression, cases cochées)
//   Azur clair #70D6FF
//   Menthe / Ambre / Alerte : états de la batterie
// ---------------------------------------------------------------------------
const _text = Color(0xFFF2F4F8);
const _muted = Color(0xFF8A93A6);
const _mint = Color(0xFF5BE3A8);
const _amber = Color(0xFFFFB547);
const _alert = Color(0xFFFF5A52);

/// Couleurs qui suivent le fond d'écran : elles sont modifiées pendant
/// l'exécution (contrairement aux couleurs fixes ci-dessus).
///   bg         fond de la pilule (quasi noir, avec une teinte à peine visible)
///   accent     onglet actif, progression, cases cochées, points...
///   accentSoft version plus claire de l'accent (textes et icônes actifs)
class Palette {
  static const _defaultBg = Color(0xFF03050C);
  static const _defaultAccent = Color(0xFF19B8FF);
  static const _defaultAccentSoft = Color(0xFF70D6FF);

  static Color bg = _defaultBg;
  static Color accent = _defaultAccent;
  static Color accentSoft = _defaultAccentSoft;

  /// Retour aux couleurs d'origine (bleu azur sur noir).
  static void reset() {
    bg = _defaultBg;
    accent = _defaultAccent;
    accentSoft = _defaultAccentSoft;
  }

  /// Calcule les trois couleurs à partir de la couleur dominante du fond d'écran.
  static void applyFrom(HSVColor dominant) {
    final hue = dominant.hue;

    // Accent vif, mais jamais terne.
    var saturation = dominant.saturation.clamp(0.55, 0.95).toDouble();
    var color = HSVColor.fromAHSV(1, hue, saturation, 0.98).toColor();

    // Les bleus et violets purs sont sombres sur du noir : on les éclaircit
    // jusqu'à ce qu'ils restent lisibles.
    while (color.computeLuminance() < 0.2 && saturation > 0.25) {
      saturation -= 0.05;
      color = HSVColor.fromAHSV(1, hue, saturation, 0.98).toColor();
    }

    accent = color;
    accentSoft = HSVColor.fromAHSV(
      1,
      hue,
      (saturation * 0.5).clamp(0.28, 0.55).toDouble(),
      1.0,
    ).toColor();
    bg = HSVColor.fromAHSV(1, hue, 0.6, 0.10).toColor();
  }
}

/// Cherche la couleur vive dominante d'une image (le fond d'écran).
/// Renvoie null si l'image est presque sans couleur (gris, noir, blanc).
Future<HSVColor?> dominantWallpaperColor(Uint8List bytes) async {
  // On travaille sur une miniature : plus rapide, et suffisant pour une couleur.
  final codec = await ui.instantiateImageCodec(bytes, targetWidth: 64);
  try {
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final pixelCount = image.width * image.height;
    image.dispose();
    if (data == null || pixelCount == 0) return null;

    const bins = 24; // on découpe le cercle des teintes en 24 parts
    final weight = List<double>.filled(bins, 0);
    final sumCos = List<double>.filled(bins, 0);
    final sumSin = List<double>.filled(bins, 0);
    final sumSat = List<double>.filled(bins, 0);
    final sumVal = List<double>.filled(bins, 0);
    var vivid = 0;

    for (var i = 0; i + 3 < data.lengthInBytes; i += 4) {
      if (data.getUint8(i + 3) < 200) continue;

      final hsv = HSVColor.fromColor(
        Color.fromARGB(
          255,
          data.getUint8(i),
          data.getUint8(i + 1),
          data.getUint8(i + 2),
        ),
      );

      // On ignore les gris, les noirs et les couleurs délavées.
      if (hsv.saturation < 0.28 || hsv.value < 0.22) continue;
      vivid++;

      // Plus un pixel est vif, plus il compte.
      final w = hsv.saturation * hsv.value;
      final bin = (hsv.hue / 360 * bins).floor() % bins;
      final rad = hsv.hue * math.pi / 180;

      weight[bin] += w;
      sumCos[bin] += math.cos(rad) * w;
      sumSin[bin] += math.sin(rad) * w;
      sumSat[bin] += hsv.saturation * w;
      sumVal[bin] += hsv.value * w;
    }

    // Moins de 4 % de pixels colorés : pas d'accent à en tirer.
    if (vivid < pixelCount * 0.04) return null;

    // Meilleure famille de teintes : une part et ses deux voisines.
    var best = 0;
    var bestWeight = -1.0;
    for (var b = 0; b < bins; b++) {
      final w = weight[(b + bins - 1) % bins] + weight[b] + weight[(b + 1) % bins];
      if (w > bestWeight) {
        bestWeight = w;
        best = b;
      }
    }

    var c = 0.0;
    var sn = 0.0;
    var sat = 0.0;
    var val = 0.0;
    var wt = 0.0;
    for (final b in [(best + bins - 1) % bins, best, (best + 1) % bins]) {
      c += sumCos[b];
      sn += sumSin[b];
      sat += sumSat[b];
      val += sumVal[b];
      wt += weight[b];
    }
    if (wt <= 0) return null;

    var hue = math.atan2(sn, c) * 180 / math.pi;
    if (hue < 0) hue += 360;
    return HSVColor.fromAHSV(1, hue, sat / wt, val / wt);
  } finally {
    codec.dispose();
  }
}

const _displayFont = 'Segoe UI Variable Display';
const _textFont = 'Segoe UI Variable Text';

// Taille de la pilule réduite / étendue
const double collapsedW = 150;
const double collapsedH = 36;
const double expandedW = 440;
const double expandedH = 204;

// Taille de la mini-notification (charge, minuteur terminé...)
const double peekW = 320;
const double peekH = 62;

// Taille de la FENÊTRE : elle ne change JAMAIS (plus aucun redimensionnement,
// donc plus de saccade). Elle est assez grande pour l'île étendue et son
// rebond. Quand l'île est réduite, la fenêtre laisse passer les clics.
const Size expandedWindow = Size(480, 244);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: expandedWindow,
    backgroundColor: Colors.transparent,
    skipTaskbar: true,
    titleBarStyle: TitleBarStyle.hidden,
    alwaysOnTop: true,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setAsFrameless();
    await windowManager.setHasShadow(false);
    await windowManager.setAlignment(Alignment.topCenter);
    // Île réduite au démarrage : les clics traversent la fenêtre.
    await windowManager.setIgnoreMouseEvents(true);
    await windowManager.show();
  });

  runApp(const IslandApp());
}

// ===========================================================================
// DONNÉES
// ===========================================================================

// ---------------------------------------------------------------------------
// Heure + batterie
// ---------------------------------------------------------------------------
const _days = [
  'lundi',
  'mardi',
  'mercredi',
  'jeudi',
  'vendredi',
  'samedi',
  'dimanche',
];

const _months = [
  'janvier',
  'février',
  'mars',
  'avril',
  'mai',
  'juin',
  'juillet',
  'août',
  'septembre',
  'octobre',
  'novembre',
  'décembre',
];

class SystemInfo extends ChangeNotifier {
  final Battery _battery = Battery();
  Timer? _clockTimer;
  Timer? _batteryTimer;
  StreamSubscription<BatteryState>? _stateSub;

  DateTime now = DateTime.now();

  /// null = pas de batterie (PC fixe) ou valeur indisponible.
  int? batteryLevel;
  bool charging = false;
  bool full = false;

  String get timeText =>
      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

  String get dateText {
    final d = _days[now.weekday - 1];
    final day = '${d[0].toUpperCase()}${d.substring(1)}';
    return '$day ${now.day} ${_months[now.month - 1]}';
  }

  void start() {
    // Horloge : on vérifie chaque seconde, mais on ne redessine
    // que quand la minute change.
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final n = DateTime.now();
      if (n.minute != now.minute || n.hour != now.hour) {
        now = n;
        notifyListeners();
      }
    });

    // Batterie : lecture au démarrage, puis toutes les 30 s
    // et à chaque changement d'état (branché / débranché).
    _refreshBattery();
    _batteryTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refreshBattery(),
    );
    try {
      _stateSub = _battery.onBatteryStateChanged.listen(
        (_) => _refreshBattery(),
        onError: (_) {},
      );
    } catch (_) {
      // Pas de support / pas de batterie : on ignore.
    }
  }

  Future<void> _refreshBattery() async {
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;

      final int? newLevel = level >= 0 ? level : null;
      final newCharging = state == BatteryState.charging;
      final newFull = state == BatteryState.full;

      if (newLevel != batteryLevel ||
          newCharging != charging ||
          newFull != full) {
        batteryLevel = newLevel;
        charging = newCharging;
        full = newFull;
        notifyListeners();
      }
    } catch (_) {
      if (batteryLevel != null) {
        batteryLevel = null;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _batteryTimer?.cancel();
    _stateSub?.cancel();
    super.dispose();
  }
}

Color batteryRingColor(int level, bool charging) {
  if (charging) return _mint;
  if (level <= 10) return _alert;
  if (level <= 20) return _amber;
  return _text;
}

// ---------------------------------------------------------------------------
// Média en cours (Spotify, YouTube, Apple Music...) via le pont C#
// "media_bridge.exe" : il lit le média de Windows et nous envoie des lignes
// JSON ; on lui envoie des commandes (lecture/pause, suivant, précédent...).
// ---------------------------------------------------------------------------
class LyricLine {
  const LyricLine(this.time, this.text);

  final double time;
  final String text;
}

enum LyricsState { idle, loading, ready, missing }

/// Transforme un texte au format LRC ("[01:23.45] paroles") en lignes datées.
List<LyricLine> parseLrc(String raw) {
  final re = RegExp(r'^\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\](.*)$');
  final out = <LyricLine>[];

  for (final line in raw.split('\n')) {
    final m = re.firstMatch(line.trim());
    if (m == null) continue;

    final text = m.group(4)!.trim();
    if (text.isEmpty) continue;

    final minutes = int.parse(m.group(1)!);
    final seconds = int.parse(m.group(2)!);
    final fracStr = m.group(3);
    final frac =
        fracStr == null ? 0.0 : int.parse(fracStr) / math.pow(10, fracStr.length);

    out.add(LyricLine(minutes * 60 + seconds + frac, text));
  }

  out.sort((a, b) => a.time.compareTo(b.time));
  return out;
}

String _cleanTitle(String title) {
  final cleaned = title
      .replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), '')
      .replaceAll(
        RegExp(r'official\s*(music\s*)?video|lyrics|audio', caseSensitive: false),
        '',
      )
      .trim();
  return cleaned.isEmpty ? title : cleaned;
}

/// Cherche des paroles synchronisées sur LRCLIB (service public et gratuit).
/// Le titre et l'artiste sont envoyés à ce service : on ne le fait que si
/// l'utilisateur ouvre lui-même la vue "Paroles".
Future<List<LyricLine>> fetchSyncedLyrics(String title, String artist) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    final uri = Uri.https('lrclib.net', '/api/search', {
      'track_name': _cleanTitle(title),
      'artist_name': artist,
    });
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, 'DynamicIslandWindows/0.1');
    final response = await request.close().timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return const [];

    final body = await response.transform(utf8.decoder).join();
    final results = jsonDecode(body) as List;
    for (final entry in results) {
      final map = entry as Map<String, dynamic>;
      final synced = map['syncedLyrics'];
      if (synced is String && synced.trim().isNotEmpty) {
        return parseLrc(synced);
      }
    }
    return const [];
  } finally {
    client.close(force: true);
  }
}

class MediaStore extends ChangeNotifier {
  Process? _proc;
  StreamSubscription<String>? _sub;
  Timer? _restart;
  bool _disposed = false;

  /// Le fichier media_bridge.exe a-t-il été trouvé ?
  bool bridgeFound = false;

  /// Reçoit les messages du pont qui ne concernent pas le média
  /// (volume, luminosité, Verr. Maj, Bluetooth, plein écran).
  void Function(Map<String, dynamic> message)? onEvent;

  bool active = false;
  bool playing = false;
  String title = '';
  String artist = '';
  String app = '';
  double duration = 0;
  Uint8List? art;

  double _position = 0;
  DateTime _stamp = DateTime.now();
  String _trackKey = '';

  // Paroles
  bool lyricsWanted = false;
  LyricsState lyricsState = LyricsState.idle;
  List<LyricLine> lyrics = const [];
  String _lyricsKey = '';

  /// Position actuelle, estimée entre deux messages du pont.
  double get position {
    if (!playing) return _position;
    final p = _position + DateTime.now().difference(_stamp).inMilliseconds / 1000;
    return duration > 0 ? math.min(p, duration) : p;
  }

  String? _findBridge() {
    final sep = Platform.pathSeparator;
    final candidates = <String>[];

    // À côté de l'application (version installée), puis dans les dossiers
    // parents : en développement, "media_bridge/out" est à la racine du projet,
    // plusieurs niveaux au-dessus de l'exécutable (build/windows/.../Release).
    // Ainsi, ça marche aussi quand Windows lance l'appli au démarrage, où le
    // "dossier de travail" n'est pas celui du projet.
    var dir = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 8; i++) {
      candidates.add('${dir.path}${sep}media_bridge.exe');
      candidates.add(
        '${dir.path}${sep}media_bridge${sep}out${sep}media_bridge.exe',
      );
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }

    // Lancement avec "flutter run" depuis la racine du projet.
    candidates.add(
      '${Directory.current.path}${sep}media_bridge${sep}out${sep}media_bridge.exe',
    );

    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  Future<void> start() async {
    if (_disposed) return;

    final exe = _findBridge();
    if (exe == null) {
      bridgeFound = false;
      notifyListeners();
      return;
    }
    bridgeFound = true;

    try {
      final proc = await Process.start(exe, const []);
      if (_disposed) {
        proc.kill();
        return;
      }
      _proc = proc;

      _sub = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onLine, onError: (_) {});
      proc.stderr.listen((_) {});

      proc.exitCode.then((_) {
        _proc = null;
        if (_disposed) return;
        _resetMedia();
        _restart = Timer(const Duration(seconds: 3), start);
      });
    } catch (_) {
      if (!_disposed) {
        _restart = Timer(const Duration(seconds: 10), start);
      }
    }
  }

  void _resetMedia() {
    active = false;
    playing = false;
    title = '';
    artist = '';
    app = '';
    duration = 0;
    _position = 0;
    art = null;
    _trackKey = '';
    _lyricsKey = '';
    lyrics = const [];
    lyricsState = LyricsState.idle;
    notifyListeners();
  }

  void _onLine(String line) {
    try {
      final j = jsonDecode(line) as Map<String, dynamic>;
      final type = j['t'];

      if (type == 'media') {
        _onMedia(j);
      } else if (type == 'art') {
        if (j['key'] == _trackKey) {
          art = base64Decode(j['data'] as String);
          notifyListeners();
        }
      } else {
        onEvent?.call(j);
      }
    } catch (_) {
      // Ligne illisible : on l'ignore.
    }
  }

  void _onMedia(Map<String, dynamic> j) {
    if (j['active'] != true) {
      if (active) _resetMedia();
      return;
    }

    final newTitle = (j['title'] as String?) ?? '';
    final newArtist = (j['artist'] as String?) ?? '';
    final key = '$newTitle|$newArtist';
    final trackChanged = key != _trackKey;

    active = true;
    title = newTitle;
    artist = newArtist;
    playing = j['playing'] == true;
    app = (j['app'] as String?) ?? '';

    var pos = (j['pos'] as num?)?.toDouble() ?? 0;
    var dur = (j['dur'] as num?)?.toDouble() ?? 0;

    // Direct, vidéo en continu... : certains lecteurs donnent des valeurs
    // absurdes (un horodatage à la place d'une durée, par exemple). Si la durée
    // est nulle, dépasse 48 h, ou si la position la dépasse, on considère
    // qu'il n'y a ni durée ni progression à afficher.
    if (dur <= 0 || dur > 48 * 3600 || pos < 0 || pos > dur + 5) {
      pos = 0;
      dur = 0;
    }

    _position = pos;
    duration = dur;
    _stamp = DateTime.now();

    if (trackChanged) {
      _trackKey = key;
      art = null;
      _lyricsKey = '';
      lyrics = const [];
      lyricsState = LyricsState.idle;
      if (lyricsWanted) loadLyrics();
    }

    notifyListeners();
  }

  // --- Commandes -----------------------------------------------------------
  void _send(String cmd) {
    try {
      _proc?.stdin.writeln(cmd);
    } catch (_) {
      // Pont arrêté : il sera relancé automatiquement.
    }
  }

  void playPause() {
    _send('play_pause');
    // On met l'interface à jour tout de suite, sans attendre le pont.
    _position = position;
    _stamp = DateTime.now();
    playing = !playing;
    notifyListeners();
  }

  void next() => _send('next');

  void previous() => _send('prev');

  void seek(double seconds) {
    final target = duration > 0 ? seconds.clamp(0.0, duration).toDouble() : seconds;
    _send('seek:${target.toStringAsFixed(1)}');
    _position = target;
    _stamp = DateTime.now();
    notifyListeners();
  }

  // --- Paroles -------------------------------------------------------------
  void setLyricsWanted(bool value) {
    lyricsWanted = value;
    if (value) loadLyrics();
    notifyListeners();
  }

  Future<void> loadLyrics() async {
    if (!active || title.isEmpty) return;

    final key = _trackKey;
    if (_lyricsKey == key && lyricsState != LyricsState.idle) return;

    _lyricsKey = key;
    lyricsState = LyricsState.loading;
    lyrics = const [];
    notifyListeners();

    var result = const <LyricLine>[];
    try {
      result = await fetchSyncedLyrics(title, artist);
    } catch (_) {
      // Pas de réseau ou service indisponible : "introuvables".
    }

    if (_disposed || key != _trackKey) return;
    lyrics = result;
    lyricsState = result.isEmpty ? LyricsState.missing : LyricsState.ready;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _restart?.cancel();
    _sub?.cancel();
    _proc?.kill();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Presse-papiers : historique du texte copié (gardé en mémoire uniquement,
// jamais écrit sur le disque, et le contenu déjà présent au lancement est
// ignoré).
// ---------------------------------------------------------------------------
class ClipboardStore extends ChangeNotifier {
  static const _maxItems = 12;
  static const _maxLength = 2000;

  final List<String> items = [];
  Timer? _timer;
  String? _last;
  bool _primed = false;

  void start() {
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  Future<void> _poll() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;

      // Premier passage : on mémorise sans afficher.
      if (!_primed) {
        _primed = true;
        _last = text;
        return;
      }

      if (text == null || text.trim().isEmpty || text == _last) return;
      _last = text;

      final stored =
          text.length > _maxLength ? text.substring(0, _maxLength) : text;
      items.remove(stored);
      items.insert(0, stored);
      if (items.length > _maxItems) {
        items.removeRange(_maxItems, items.length);
      }
      notifyListeners();
    } catch (_) {
      // Presse-papiers occupé : on réessaiera au prochain passage.
    }
  }

  Future<void> copy(String text) async {
    _last = text;
    await Clipboard.setData(ClipboardData(text: text));
  }

  void clear() {
    items.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// To-Do : sauvegardée sur le disque (shared_preferences)
// ---------------------------------------------------------------------------
class TodoItem {
  TodoItem(this.title, {this.done = false});

  final String title;
  bool done;

  Map<String, dynamic> toJson() => {'t': title, 'd': done};

  factory TodoItem.fromJson(Map<String, dynamic> json) =>
      TodoItem(json['t'] as String, done: (json['d'] as bool?) ?? false);
}

class TodoStore extends ChangeNotifier {
  static const _key = 'island_todos';

  final List<TodoItem> items = [];
  SharedPreferences? _prefs;

  int get doneCount => items.where((e) => e.done).length;

  Future<void> load() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      final raw = _prefs!.getString(_key);
      if (raw == null) return;
      final list = jsonDecode(raw) as List;
      items
        ..clear()
        ..addAll(
          list.map((e) => TodoItem.fromJson(Map<String, dynamic>.from(e as Map))),
        );
      notifyListeners();
    } catch (_) {
      // Données illisibles : on repart d'une liste vide.
    }
  }

  void _save() {
    _prefs?.setString(
      _key,
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }

  void add(String title) {
    final t = title.trim();
    if (t.isEmpty) return;
    items.insert(0, TodoItem(t));
    _save();
    notifyListeners();
  }

  void toggle(TodoItem item) {
    item.done = !item.done;
    _save();
    notifyListeners();
  }

  void remove(TodoItem item) {
    items.remove(item);
    _save();
    notifyListeners();
  }

  void clearDone() {
    items.removeWhere((e) => e.done);
    _save();
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// Minuteur / Pomodoro
// ---------------------------------------------------------------------------
String _fmtClock(int totalSeconds) {
  final s = totalSeconds < 0 ? 0 : totalSeconds;
  final m = s ~/ 60;
  final r = s % 60;
  return '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
}

enum TimerKind {
  focus('Focus', 25),
  shortBreak('Pause', 5),
  longBreak('Longue', 15);

  const TimerKind(this.label, this.minutes);

  final String label;
  final int minutes;
}

class TimerStore extends ChangeNotifier {
  TimerKind kind = TimerKind.focus;
  int totalSeconds = TimerKind.focus.minutes * 60;
  int remainingSeconds = TimerKind.focus.minutes * 60;
  bool running = false;
  int completedFocus = 0;

  /// Appelé quand un minuteur arrive à zéro (avec le type qui vient de finir).
  void Function(TimerKind finished)? onFinished;

  DateTime? _endAt;
  Timer? _tick;

  bool get isBreak => kind != TimerKind.focus;

  double get progress =>
      totalSeconds == 0 ? 0.0 : remainingSeconds / totalSeconds;

  /// Vrai quand le minuteur doit remplacer l'affichage de la pilule réduite :
  /// il tourne, ou il est en pause en cours de route.
  bool get isActive =>
      running || (remainingSeconds < totalSeconds && remainingSeconds > 0);

  void select(TimerKind k) {
    _stop();
    kind = k;
    totalSeconds = k.minutes * 60;
    remainingSeconds = totalSeconds;
    notifyListeners();
  }

  void adjustMinutes(int delta) {
    if (running || remainingSeconds != totalSeconds) return;
    final minutes = ((totalSeconds ~/ 60) + delta).clamp(1, 180).toInt();
    totalSeconds = minutes * 60;
    remainingSeconds = totalSeconds;
    notifyListeners();
  }

  void toggle() {
    if (running) {
      pause();
    } else {
      start();
    }
  }

  void start() {
    if (remainingSeconds <= 0) remainingSeconds = totalSeconds;
    running = true;
    _endAt = DateTime.now().add(Duration(seconds: remainingSeconds));
    _tick?.cancel();
    _tick = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _onTick(),
    );
    notifyListeners();
  }

  void pause() {
    _stop();
    notifyListeners();
  }

  void reset() {
    _stop();
    remainingSeconds = totalSeconds;
    notifyListeners();
  }

  void _stop() {
    running = false;
    _tick?.cancel();
    _tick = null;
    _endAt = null;
  }

  void _onTick() {
    final end = _endAt;
    if (end == null) return;

    // Arrondi vers le haut : "00:01" reste affiché jusqu'à la toute fin.
    final left = (end.difference(DateTime.now()).inMilliseconds / 1000).ceil();

    if (left <= 0) {
      _finish();
    } else if (left != remainingSeconds) {
      remainingSeconds = left;
      notifyListeners();
    }
  }

  void _finish() {
    final finished = kind;
    _stop();

    // Enchaînement façon Pomodoro : focus, puis pause (longue toutes les
    // 4 sessions), puis de nouveau focus. La suite est prête mais pas lancée.
    if (finished == TimerKind.focus) {
      completedFocus++;
      kind = completedFocus % 4 == 0
          ? TimerKind.longBreak
          : TimerKind.shortBreak;
    } else {
      kind = TimerKind.focus;
    }
    totalSeconds = kind.minutes * 60;
    remainingSeconds = totalSeconds;

    SystemSound.play(SystemSoundType.alert).catchError((_) {});
    notifyListeners();
    onFinished?.call(finished);
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Mini-notification affichée un instant dans la pilule
// ---------------------------------------------------------------------------
class IslandPeek {
  const IslandPeek({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    this.trailing,
    this.progress,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final String? trailing;
  final double? progress;
}

// ---------------------------------------------------------------------------
// Réglages (sauvegardés sur le disque)
// ---------------------------------------------------------------------------
class SettingsStore extends ChangeNotifier {
  // Mini-notifications
  bool notifBattery = true;
  bool notifTimer = true;
  bool notifBluetooth = true;

  // Affichage
  bool hideInFullscreen = true;
  bool followWallpaper = true;
  int manualAccent = 0xFF19B8FF;
  double topGap = 10;

  // Système : lancement avec Windows (lu directement dans le registre Windows,
  // pas dans nos préférences, pour toujours refléter la réalité).
  bool autoStart = false;
  bool autoStartAvailable = true;

  SharedPreferences? _prefs;

  Future<void> load() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      final p = _prefs!;
      notifBattery = p.getBool('set_notif_battery') ?? true;
      notifTimer = p.getBool('set_notif_timer') ?? true;
      notifBluetooth = p.getBool('set_notif_bluetooth') ?? true;
      hideInFullscreen = p.getBool('set_hide_fullscreen') ?? true;
      followWallpaper = p.getBool('set_follow_wallpaper') ?? true;
      manualAccent = p.getInt('set_manual_accent') ?? 0xFF19B8FF;
      topGap = (p.getDouble('set_top_gap') ?? 10).clamp(0.0, 20.0).toDouble();
    } catch (_) {
      // Préférences illisibles : on garde les valeurs par défaut.
    }

    try {
      launchAtStartup.setup(
        appName: 'DynamicIsland',
        appPath: Platform.resolvedExecutable,
      );
      autoStart = await launchAtStartup.isEnabled();
    } catch (e) {
      autoStartAvailable = false;
      debugPrint('[île] lancement automatique indisponible : $e');
    }

    notifyListeners();
  }

  void _saveBool(String key, bool value) => _prefs?.setBool(key, value);

  void setNotifBattery(bool v) {
    notifBattery = v;
    _saveBool('set_notif_battery', v);
    notifyListeners();
  }

  void setNotifTimer(bool v) {
    notifTimer = v;
    _saveBool('set_notif_timer', v);
    notifyListeners();
  }

  void setNotifBluetooth(bool v) {
    notifBluetooth = v;
    _saveBool('set_notif_bluetooth', v);
    notifyListeners();
  }

  void setHideInFullscreen(bool v) {
    hideInFullscreen = v;
    _saveBool('set_hide_fullscreen', v);
    notifyListeners();
  }

  void setFollowWallpaper(bool v) {
    followWallpaper = v;
    _saveBool('set_follow_wallpaper', v);
    notifyListeners();
  }

  void setManualAccent(int argb) {
    manualAccent = argb;
    _prefs?.setInt('set_manual_accent', argb);
    notifyListeners();
  }

  void adjustTopGap(double delta) {
    topGap = (topGap + delta).clamp(0.0, 20.0).toDouble();
    _prefs?.setDouble('set_top_gap', topGap);
    notifyListeners();
  }

  Future<void> setAutoStart(bool v) async {
    try {
      if (v) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }
      autoStart = await launchAtStartup.isEnabled();
    } catch (e) {
      debugPrint('[île] changement du lancement automatique impossible : $e');
    }
    notifyListeners();
  }
}

/// Couleurs proposées quand on ne suit pas le fond d'écran.
const _manualAccents = <Color>[
  Color(0xFF19B8FF), // azur (par défaut)
  Color(0xFF7C6CFF), // violet
  Color(0xFFFF5CA8), // rose
  Color(0xFFFF6B5C), // corail
  Color(0xFFFFA23A), // orange
  Color(0xFFFFD43B), // jaune
  Color(0xFF3DDC97), // vert
  Color(0xFF2FD6D0), // turquoise
];

// ===========================================================================
// APPLICATION
// ===========================================================================
enum IslandTab {
  home(Icons.schedule_rounded, 'Accueil'),
  music(Icons.music_note_rounded, 'Musique'),
  clipboard(Icons.content_paste_rounded, 'Presse-papiers'),
  todo(Icons.checklist_rounded, 'À faire'),
  timer(Icons.timer_rounded, 'Minuteur'),
  settings(Icons.tune_rounded, 'Réglages');

  const IslandTab(this.icon, this.label);

  final IconData icon;
  final String label;
}

class IslandApp extends StatelessWidget {
  const IslandApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const Scaffold(
        backgroundColor: Colors.transparent,
        body: Island(),
      ),
    );
  }
}

class Island extends StatefulWidget {
  const Island({super.key});

  @override
  State<Island> createState() => _IslandState();
}

class _IslandState extends State<Island> {
  static const _expandDuration = Duration(milliseconds: 450);
  static const _collapseDuration = Duration(milliseconds: 320);

  final SystemInfo _info = SystemInfo();
  final MediaStore _media = MediaStore();
  final ClipboardStore _clipboard = ClipboardStore();
  final TodoStore _todos = TodoStore();
  final TimerStore _timer = TimerStore();
  final SettingsStore _settings = SettingsStore();

  // Mini-notification : _peek = celle qui est visible, _peekContent = la
  // dernière affichée (gardée pour pouvoir disparaître en fondu).
  IslandPeek? _peek;
  IslandPeek? _peekContent;
  Timer? _peekTimer;

  // Vrai quand une appli est en plein écran : l'île se masque.
  bool _fullscreenHidden = false;

  // Windows signale une appli en plein écran (même si on a choisi, dans les
  // réglages, de ne pas masquer l'île).
  bool _fullscreenReported = false;

  // Pour ne refaire le travail des couleurs que quand le réglage change.
  bool? _lastFollowWallpaper;
  int? _lastManualAccent;

  // Alerte importante qui n'a pas pu s'afficher (île ouverte ou masquée) :
  // elle est montrée dès que possible, pour ne jamais être perdue.
  IslandPeek? _pendingAlert;

  // Niveau d'alerte de batterie déjà donné par appareil Bluetooth
  // (0 = aucun, 1 = batterie faible, 2 = critique).
  final Map<String, int> _btLowStage = {};

  // Suivi de la batterie pour déclencher les mini-notifications.
  bool _batteryPrimed = false;
  bool _prevCharging = false;
  bool _prevFull = false;
  int _lowStage = 0; // 0 = rien, 1 = alerte à 20 %, 2 = alerte à 10 %

  IslandTab _tab = IslandTab.home;
  bool _expanded = false;
  bool _hovering = false;
  bool _pinned = false;
  Timer? _ignoreTimer;
  Timer? _pollTimer;
  bool _polling = false;
  Rect? _windowBounds;
  int _pollCount = 0;
  bool _errorLogged = false;

  /// Unité des coordonnées du curseur par rapport aux pixels "logiques" de
  /// Flutter : 1.0 si elles sont identiques, ou le facteur d'échelle de
  /// l'écran (1.25, 1.5...) si le curseur est donné en pixels physiques.
  double _unit = 1.0;

  @override
  void initState() {
    super.initState();
    _info.start();
    _media.start();
    _clipboard.start();
    _todos.load();
    _timer.onFinished = _onTimerFinished;
    _media.onEvent = _onBridgeEvent;
    _settings.addListener(_onSettingsChanged);
    _settings.load();
    _info.addListener(_onInfoChanged);
    _startCursorWatch();
    _startWallpaperWatch();
  }

  // --- Réglages --------------------------------------------------------------
  void _onSettingsChanged() {
    if (!mounted) return;

    // Couleurs : fond d'écran ou couleur choisie à la main.
    final follow = _settings.followWallpaper;
    final manual = _settings.manualAccent;
    if (follow != _lastFollowWallpaper ||
        (!follow && manual != _lastManualAccent)) {
      _lastFollowWallpaper = follow;
      _lastManualAccent = manual;
      if (follow) {
        _wallpaperChecked = false;
        _checkWallpaper();
      } else {
        _applyPalette(HSVColor.fromColor(Color(manual)));
      }
    }

    // Masquage en plein écran activé ou désactivé.
    _applyFullscreen();

    // Rafraîchit ce qui dépend des réglages (distance au bord, par exemple).
    setState(() {});
  }

  void _applyFullscreen() {
    _setFullscreen(_fullscreenReported && _settings.hideInFullscreen);
  }

  // --- Couleurs qui suivent le fond d'écran ----------------------------------
  Timer? _wallpaperTimer;
  DateTime? _wallpaperStamp;
  bool _wallpaperChecked = false;
  bool _wallpaperBusy = false;

  void _startWallpaperWatch() {
    _checkWallpaper();
    _wallpaperTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _checkWallpaper(),
    );
  }

  // Windows réécrit le fichier "TranscodedWallpaper" à chaque changement de
  // fond d'écran (y compris en diaporama) : on surveille sa date de
  // modification et on recalcule les couleurs seulement quand elle change.
  Future<void> _checkWallpaper() async {
    if (_wallpaperBusy || !_settings.followWallpaper) return;
    _wallpaperBusy = true;
    try {
      final appData = Platform.environment['APPDATA'];
      if (appData == null) return;

      final sep = Platform.pathSeparator;
      final file = File(
        '$appData${sep}Microsoft${sep}Windows${sep}Themes${sep}TranscodedWallpaper',
      );

      if (!await file.exists()) {
        // Pas d'image (couleur unie, par exemple) : couleurs d'origine.
        if (!_wallpaperChecked) _applyPalette(null);
        _wallpaperChecked = true;
        return;
      }

      final stamp = (await file.stat()).modified;
      if (_wallpaperChecked && stamp == _wallpaperStamp) return;
      _wallpaperChecked = true;
      _wallpaperStamp = stamp;

      _applyPalette(await dominantWallpaperColor(await file.readAsBytes()));
    } catch (e) {
      debugPrint('[île] fond d\'écran illisible : $e');
    } finally {
      _wallpaperBusy = false;
    }
  }

  void _applyPalette(HSVColor? color) {
    if (!mounted) return;
    setState(() {
      if (color == null) {
        Palette.reset();
      } else {
        Palette.applyFrom(color);
      }
    });
  }

  // --- Détection du survol ---------------------------------------------------
  // La fenêtre garde TOUJOURS la même taille. Quand l'île est réduite, elle
  // est "traversable" : les clics passent aux applis dessous. Comme elle ne
  // reçoit alors plus d'événements de survol, on lit la position du curseur
  // toutes les 60 ms pour savoir quand ouvrir ou fermer l'île.
  Future<void> _startCursorWatch() async {
    await _calibrateCursor();
    await _placeWindow();
    if (!mounted) return;
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 60),
      (_) => _pollCursor(),
    );
  }

  // Windows peut donner la position du curseur en pixels physiques alors que
  // la position de la fenêtre est en pixels logiques (écran à 125 %, 150 %...).
  // On compare la taille de l'écran donnée par screen_retriever à celle que
  // Flutter connaît pour savoir dans quelle unité on est.
  Future<void> _calibrateCursor() async {
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final physicalW = view.display.size.width;
      final dpr = view.devicePixelRatio;
      final w = display.size.width;

      final asPhysical = (w - physicalW).abs();
      final asLogical = (w - physicalW / dpr).abs();
      _unit = asPhysical < asLogical ? dpr : 1.0;

      debugPrint(
        '[île] écran screen_retriever=${display.size} '
        'physique=${view.display.size} dpr=$dpr',
      );
    } catch (e) {
      debugPrint('[île] calibration impossible : $e');
    }
  }

  // On place nous-mêmes la fenêtre en haut au centre de l'écran, à partir de
  // la zone utile de l'écran (sans la barre des tâches), au lieu de se fier à
  // la position lue sur la fenêtre. On retient ces coordonnées pour calculer
  // la zone de survol.
  Future<void> _placeWindow() async {
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      final origin = (display.visiblePosition ?? Offset.zero) / _unit;
      final size = (display.visibleSize ?? display.size) / _unit;

      final left = origin.dx + (size.width - expandedWindow.width) / 2;
      final top = origin.dy;

      await windowManager.setBounds(
        null,
        position: Offset(left, top),
        size: expandedWindow,
      );
      _windowBounds = Rect.fromLTWH(
        left,
        top,
        expandedWindow.width,
        expandedWindow.height,
      );

      final actual = await windowManager.getBounds();
      debugPrint(
        '[île] fenêtre demandée=$_windowBounds  lue sur la fenêtre=$actual  '
        'unité=$_unit',
      );
    } catch (e) {
      debugPrint('[île] placement de la fenêtre impossible : $e');
      // Plan de secours : on part de la position lue sur la fenêtre.
      _windowBounds = await windowManager.getBounds();
    }
  }

  // Zone qui déclenche / maintient l'ouverture. Elle monte jusqu'en haut de
  // l'écran (amener la souris tout en haut ouvre l'île) et elle est un peu plus
  // large quand l'île est ouverte, pour éviter qu'elle se ferme au moindre
  // écart.
  Rect _hitRect() {
    final wb = _windowBounds!;
    final size = _pillSize;
    final w = size.width;
    final h = size.height;
    final left = wb.left + (wb.width - w) / 2;
    final pad = _expanded ? 14.0 : 8.0;
    return Rect.fromLTRB(
      left - pad,
      wb.top,
      left + w + pad,
      wb.top + _settings.topGap + h + pad,
    );
  }

  Future<void> _pollCursor() async {
    if (_polling || _windowBounds == null || _fullscreenHidden) return;
    _polling = true;
    try {
      final raw = await screenRetriever.getCursorScreenPoint();
      final p = raw / _unit; // en pixels logiques, comme la fenêtre
      final inside = _hitRect().contains(p);

      // Journal de diagnostic : seulement quand la souris est près du haut.
      _pollCount++;
      if (p.dy < 120 && _pollCount % 8 == 0) {
        debugPrint('[île] curseur=$raw → $p  zone=${_hitRect()}  dedans=$inside');
      }

      if (mounted && inside != _hovering) {
        if (inside) {
          _onEnter();
        } else {
          _onExit();
        }
      }
    } catch (e) {
      // Lecture du curseur impossible à cet instant : on réessaie.
      if (!_errorLogged) {
        _errorLogged = true;
        debugPrint('[île] lecture du curseur impossible : $e');
      }
    } finally {
      _polling = false;
    }
  }

  void _onEnter() {
    _hovering = true;
    _ignoreTimer?.cancel();
    if (_expanded) return;
    // La fenêtre devient cliquable pendant que l'île est ouverte.
    windowManager.setIgnoreMouseEvents(false);
    _peekTimer?.cancel();
    setState(() {
      _peek = null;
      _expanded = true;
    });
  }

  // À la sortie : on referme l'île, puis, une fois l'animation terminée, la
  // fenêtre redevient traversable. Si l'île est épinglée, elle reste ouverte.
  void _onExit() {
    _hovering = false;
    if (_pinned) return;
    _collapse();
  }

  void _collapse() {
    setState(() => _expanded = false);
    _ignoreTimer?.cancel();
    _ignoreTimer = Timer(
      _collapseDuration + const Duration(milliseconds: 80),
      () => windowManager.setIgnoreMouseEvents(true),
    );
    // Une alerte importante attendait que l'île se referme.
    Future.delayed(const Duration(milliseconds: 700), _flushPendingAlert);
  }

  void _togglePin() {
    setState(() => _pinned = !_pinned);
    if (!_pinned && !_hovering) _collapse();
  }

  // --- Taille de la pilule selon son état ---------------------------------
  bool get _growing => _expanded || _peek != null;

  Size get _pillSize {
    if (_expanded) return const Size(expandedW, expandedH);
    if (_peek != null) return const Size(peekW, peekH);
    return const Size(collapsedW, collapsedH);
  }

  // --- Mini-notifications ----------------------------------------------------
  void _showPeek(
    IslandPeek peek, {
    Duration duration = const Duration(milliseconds: 3200),
    bool important = false,
  }) {
    if (!mounted) return;

    // Si l'île est ouverte, l'utilisateur regarde déjà : pas de mini-notif.
    // Si une appli est en plein écran, on ne la dérange pas. Une alerte
    // importante n'est pas perdue pour autant : elle attend son tour.
    if (_expanded || _fullscreenHidden) {
      if (important) _pendingAlert = peek;
      return;
    }

    _peekTimer?.cancel();
    setState(() {
      _peek = peek;
      _peekContent = peek;
    });
    _peekTimer = Timer(duration, () {
      if (mounted) setState(() => _peek = null);
    });
  }

  // Batterie d'un appareil Bluetooth connecté (casque, enceinte...).
  //  - première lecture après la connexion : on l'affiche ;
  //  - batterie faible (20 %) ou critique (10 %) : alerte, une seule fois
  //    par palier, tant que l'appareil n'a pas été rechargé.
  void _onBluetoothBattery(String name, int level, {required bool first}) {
    final stage = _btLowStage[name] ?? 0;

    // Rechargé au-dessus de 25 % : on pourra prévenir de nouveau plus tard.
    if (level > 25) _btLowStage[name] = 0;

    if (level <= 10 && stage < 2) {
      _btLowStage[name] = 2;
      // Un petit bip pour une batterie critique.
      SystemSound.play(SystemSoundType.alert).catchError((_) {});
      _showPeek(
        IslandPeek(
          icon: Icons.battery_alert_rounded,
          title: name,
          subtitle: 'Batterie critique, à recharger',
          trailing: '$level%',
          color: _alert,
          progress: level / 100,
        ),
        duration: const Duration(seconds: 6),
        important: true,
      );
    } else if (level <= 20 && stage < 1) {
      _btLowStage[name] = 1;
      _showPeek(
        IslandPeek(
          icon: Icons.battery_alert_rounded,
          title: name,
          subtitle: 'Batterie faible',
          trailing: '$level%',
          color: _amber,
          progress: level / 100,
        ),
        duration: const Duration(seconds: 5),
        important: true,
      );
    } else if (first) {
      _showPeek(
        IslandPeek(
          icon: Icons.headphones_rounded,
          title: name,
          subtitle: 'Batterie de l\'appareil',
          trailing: '$level%',
          color: level <= 30 ? _amber : Palette.accent,
          progress: level / 100,
        ),
        duration: const Duration(milliseconds: 4000),
      );
    }
  }

  // Affiche l'alerte mise en attente, si l'île est de nouveau disponible.
  void _flushPendingAlert() {
    final alert = _pendingAlert;
    if (alert == null || !mounted || _expanded || _fullscreenHidden) return;
    _pendingAlert = null;
    _showPeek(alert, duration: const Duration(seconds: 6));
  }

  // --- Événements envoyés par le pont C# ------------------------------------
  void _onBridgeEvent(Map<String, dynamic> j) {
    switch (j['t']) {
      case 'fullscreen':
        {
          _fullscreenReported = j['active'] == true;
          _applyFullscreen();
        }

      case 'btbattery':
        {
          if (!_settings.notifBluetooth) return;
          final name = (j['name'] as String?) ?? 'Appareil audio';
          final level = ((j['level'] as num?) ?? 0).round();
          _onBluetoothBattery(name, level, first: j['first'] == true);
        }

      case 'bt':
        {
          if (!_settings.notifBluetooth) return;
          final name = (j['name'] as String?) ?? 'Appareil audio';
          final connected = j['connected'] == true;
          // Nouvelle connexion ou déconnexion : on repart de zéro pour les alertes.
          _btLowStage.remove(name);
          _showPeek(
            IslandPeek(
              icon: connected
                  ? Icons.headphones_rounded
                  : Icons.bluetooth_disabled_rounded,
              title: name,
              subtitle: connected ? 'Audio connecté' : 'Déconnecté',
              color: connected ? Palette.accent : _muted,
              progress: 1.0,
            ),
            duration: const Duration(milliseconds: 3500),
          );
        }
    }
  }

  // Plein écran : l'île disparaît, ne capte plus la souris et n'est plus au
  // premier plan (pour ne jamais gêner un film, un jeu ou une présentation).
  void _setFullscreen(bool active) {
    if (!mounted || active == _fullscreenHidden) return;

    _peekTimer?.cancel();
    _ignoreTimer?.cancel();

    setState(() {
      _fullscreenHidden = active;
      if (active) {
        _peek = null;
        _expanded = false;
        _hovering = false;
      }
    });

    if (active) {
      windowManager.setIgnoreMouseEvents(true);
      windowManager.setAlwaysOnTop(false);
    } else {
      windowManager.setAlwaysOnTop(true);
      // Sortie du plein écran : on montre l'alerte qui attendait.
      Future.delayed(const Duration(milliseconds: 1200), _flushPendingAlert);
    }
  }

  // Batterie : branchement, débranchement, batterie pleine, batterie faible.
  void _onInfoChanged() {
    final level = _info.batteryLevel;
    if (level == null) return;

    final charging = _info.charging;
    final full = _info.full;

    // Première lecture : on mémorise l'état sans rien afficher.
    if (!_batteryPrimed) {
      _batteryPrimed = true;
      _prevCharging = charging;
      _prevFull = full;
      return;
    }

    // Notifications désactivées : on suit l'état sans rien afficher, pour ne
    // pas déclencher de fausses alertes à la réactivation.
    if (!_settings.notifBattery) {
      _prevCharging = charging;
      _prevFull = full;
      return;
    }

    if (charging && !_prevCharging) {
      _lowStage = 0;
      _showPeek(
        IslandPeek(
          icon: Icons.bolt_rounded,
          title: 'En charge',
          subtitle: 'Chargeur branché',
          trailing: '$level%',
          color: _mint,
          progress: level / 100,
        ),
      );
    } else if (full && !_prevFull) {
      _lowStage = 0;
      _showPeek(
        IslandPeek(
          icon: Icons.battery_full_rounded,
          title: 'Batterie pleine',
          subtitle: 'Chargeur à débrancher',
          trailing: '100%',
          color: _mint,
          progress: 1.0,
        ),
      );
    } else if (!charging && !full && (_prevCharging || _prevFull)) {
      _showPeek(
        IslandPeek(
          icon: Icons.battery_std_rounded,
          title: 'Débranché',
          subtitle: 'Sur batterie',
          trailing: '$level%',
          color: _text,
          progress: level / 100,
        ),
      );
    } else if (!charging && !full) {
      if (level <= 10 && _lowStage < 2) {
        _lowStage = 2;
        _showPeek(
          IslandPeek(
            icon: Icons.battery_alert_rounded,
            title: 'Batterie critique',
            subtitle: 'Branchez le chargeur',
            trailing: '$level%',
            color: _alert,
            progress: level / 100,
          ),
        );
      } else if (level <= 20 && _lowStage < 1) {
        _lowStage = 1;
        _showPeek(
          IslandPeek(
            icon: Icons.battery_alert_rounded,
            title: 'Batterie faible',
            subtitle: 'Pensez à brancher le chargeur',
            trailing: '$level%',
            color: _amber,
            progress: level / 100,
          ),
        );
      }
    }

    _prevCharging = charging;
    _prevFull = full;
  }

  // Minuteur terminé.
  void _onTimerFinished(TimerKind finished) {
    if (!_settings.notifTimer) return;
    final focusDone = finished == TimerKind.focus;
    _showPeek(
      IslandPeek(
        icon: focusDone ? Icons.check_circle_rounded : Icons.play_circle_rounded,
        title: focusDone ? 'Focus terminé' : 'Pause terminée',
        subtitle: focusDone
            ? 'Prends une pause de ${_timer.kind.minutes} min'
            : 'On reprend le focus ?',
        color: focusDone ? Palette.accentSoft : _mint,
        progress: 1.0,
      ),
      duration: const Duration(seconds: 6),
    );
  }

  @override
  void dispose() {
    _ignoreTimer?.cancel();
    _pollTimer?.cancel();
    _peekTimer?.cancel();
    _wallpaperTimer?.cancel();
    _settings.removeListener(_onSettingsChanged);
    _settings.dispose();
    _info.removeListener(_onInfoChanged);
    _timer.dispose();
    _info.dispose();
    _media.dispose();
    _clipboard.dispose();
    _todos.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Masquée en fondu quand une appli est en plein écran.
    return IgnorePointer(
      ignoring: _fullscreenHidden,
      child: AnimatedOpacity(
        opacity: _fullscreenHidden ? 0 : 1,
        duration: const Duration(milliseconds: 250),
        child: _buildIsland(),
      ),
    );
  }

  Widget _buildIsland() {
    return Align(
      alignment: Alignment.topCenter, // centrée en haut de l'écran
      child: MouseRegion(
        child: AnimatedContainer(
          duration: _growing ? _expandDuration : _collapseDuration,
          // Rebond quand la pilule grandit, fermeture douce (un rebond en
          // fermant ferait passer la pilule sous sa taille finale).
          curve: _growing ? Curves.easeOutBack : Curves.easeInOutCubic,
          width: _pillSize.width,
          height: _pillSize.height,
          // Espace entre le bord haut de l'écran et la pilule :
          // l'île "flotte", détachée du bord.
          margin: EdgeInsets.only(top: _settings.topGap),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Palette.bg,
            // Tous les coins sont arrondis : vraie pilule flottante.
            borderRadius: BorderRadius.circular(
              _expanded ? 36 : (_peek != null ? 31 : 18),
            ),
          ),
          child: ListenableBuilder(
            listenable: _info,
            builder: (context, _) {
              return Stack(
                alignment: Alignment.center,
                children: [
                  // Contenu réduit
                  AnimatedOpacity(
                    opacity: (_expanded || _peek != null) ? 0 : 1,
                    duration: const Duration(milliseconds: 150),
                    child: _CollapsedContent(
                      info: _info,
                      media: _media,
                      timer: _timer,
                    ),
                  ),
                  // Mini-notification (charge, minuteur terminé...)
                  if (_peekContent != null)
                    IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: (_peek != null && !_expanded) ? 1 : 0,
                        duration: Duration(
                          milliseconds: _peek != null ? 260 : 140,
                        ),
                        child: OverflowBox(
                          alignment: Alignment.topCenter,
                          minWidth: peekW,
                          maxWidth: peekW,
                          minHeight: peekH,
                          maxHeight: peekH,
                          child: _PeekContent(peek: _peekContent!),
                        ),
                      ),
                    ),
                  // Contenu étendu : ignoré par la souris tant que la pilule
                  // est réduite (sinon des boutons invisibles seraient
                  // cliquables).
                  IgnorePointer(
                    ignoring: !_expanded,
                    child: AnimatedOpacity(
                      opacity: _expanded ? 1 : 0,
                      duration: const Duration(milliseconds: 280),
                      child: AnimatedScale(
                        scale: _expanded ? 1 : 0.92,
                        alignment: Alignment.topCenter,
                        duration: const Duration(milliseconds: 380),
                        curve: Curves.easeOutCubic,
                        child: OverflowBox(
                          alignment: Alignment.topCenter,
                          minWidth: expandedW,
                          maxWidth: expandedW,
                          minHeight: expandedH,
                          maxHeight: expandedH,
                          child: _ExpandedContent(
                            info: _info,
                            media: _media,
                            clipboard: _clipboard,
                            todos: _todos,
                            timer: _timer,
                            settings: _settings,
                            tab: _tab,
                            onTab: (t) => setState(() => _tab = t),
                            pinned: _pinned,
                            onPin: _togglePin,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// CONTENU RÉDUIT
//   - média en cours : pochette + égaliseur
//   - sinon         : heure + petit anneau de batterie
// ===========================================================================
class _CollapsedContent extends StatelessWidget {
  const _CollapsedContent({
    required this.info,
    required this.media,
    required this.timer,
  });

  final SystemInfo info;
  final MediaStore media;
  final TimerStore timer;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([media, timer]),
      builder: (context, _) {
        // Priorité : minuteur, puis musique, puis heure.
        if (timer.isActive) return _CollapsedTimer(timer: timer);
        if (media.active) return _CollapsedMusic(media: media);
        return _CollapsedClock(info: info);
      },
    );
  }
}

class _CollapsedTimer extends StatelessWidget {
  const _CollapsedTimer({required this.timer});

  final TimerStore timer;

  @override
  Widget build(BuildContext context) {
    final color = timer.isBreak ? _mint : Palette.accent;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          SizedBox.square(
            dimension: 16,
            child: CustomPaint(
              painter: _RingPainter(
                progress: timer.progress,
                color: color,
                track: Colors.white.withValues(alpha: 0.14),
                stroke: 2.6,
              ),
            ),
          ),
          Text(
            _fmtClock(timer.remainingSeconds),
            style: TextStyle(
              fontFamily: _textFont,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              // En pause : le temps est grisé.
              color: timer.running ? _text : _muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _CollapsedClock extends StatelessWidget {
  const _CollapsedClock({required this.info});

  final SystemInfo info;

  @override
  Widget build(BuildContext context) {
    final level = info.batteryLevel;
    final time = Text(
      info.timeText,
      style: const TextStyle(
        fontFamily: _textFont,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
        color: _text,
      ),
    );

    // Pas de batterie (PC fixe) : on centre juste l'heure.
    if (level == null) return Center(child: time);

    return Padding(
      padding: const EdgeInsets.only(left: 18, right: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          time,
          BatteryRing(
            level: level,
            charging: info.charging,
            size: 15,
            stroke: 2.4,
          ),
        ],
      ),
    );
  }
}

class _CollapsedMusic extends StatelessWidget {
  const _CollapsedMusic({required this.media});

  final MediaStore media;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 14, right: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _Cover(art: media.art, size: 22, radius: 7),
          Equalizer(color: Palette.accent, playing: media.playing),
        ],
      ),
    );
  }
}

/// Petit égaliseur animé (immobile quand la musique est en pause).
class Equalizer extends StatefulWidget {
  const Equalizer({super.key, required this.color, required this.playing});

  final Color color;
  final bool playing;

  @override
  State<Equalizer> createState() => _EqualizerState();
}

class _EqualizerState extends State<Equalizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) _c.repeat();
  }

  @override
  void didUpdateWidget(Equalizer old) {
    super.didUpdateWidget(old);
    if (widget.playing && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.playing && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 14,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(4, (i) {
              final t = _c.value * 2 * math.pi + i * 1.3;
              final h = widget.playing
                  ? 5 + 9 * (0.5 + 0.5 * math.sin(t))
                  : 4.0;
              return Container(
                width: 3,
                height: h,
                margin: const EdgeInsets.symmetric(horizontal: 1.2),
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

// ===========================================================================
// CONTENU ÉTENDU : en-tête à onglets, page, points de pagination
// ===========================================================================
class _ExpandedContent extends StatelessWidget {
  const _ExpandedContent({
    required this.info,
    required this.media,
    required this.clipboard,
    required this.todos,
    required this.timer,
    required this.settings,
    required this.tab,
    required this.onTab,
    required this.pinned,
    required this.onPin,
  });

  final SystemInfo info;
  final MediaStore media;
  final ClipboardStore clipboard;
  final TodoStore todos;
  final TimerStore timer;
  final SettingsStore settings;
  final IslandTab tab;
  final ValueChanged<IslandTab> onTab;
  final bool pinned;
  final VoidCallback onPin;

  Widget _body() => switch (tab) {
        IslandTab.home => _HomeTab(info: info),
        IslandTab.music => _MusicTab(store: media),
        IslandTab.clipboard => _ClipboardTab(store: clipboard),
        IslandTab.todo => _TodoTab(store: todos),
        IslandTab.timer => _TimerTab(store: timer),
        IslandTab.settings => _SettingsTab(store: settings),
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Header(
          info: info,
          tab: tab,
          onTab: onTab,
          pinned: pinned,
          onPin: onPin,
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: KeyedSubtree(
              key: ValueKey(tab),
              child: SizedBox.expand(child: _body()),
            ),
          ),
        ),
        _Dots(tab: tab, onTab: onTab),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.info,
    required this.tab,
    required this.onTab,
    required this.pinned,
    required this.onPin,
  });

  final SystemInfo info;
  final IslandTab tab;
  final ValueChanged<IslandTab> onTab;
  final bool pinned;
  final VoidCallback onPin;

  @override
  Widget build(BuildContext context) {
    final level = info.batteryLevel;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 18, 0),
      child: SizedBox(
        height: 34,
        child: Row(
          children: [
            for (final t in IslandTab.values)
              Padding(
                padding: const EdgeInsets.only(right: 2),
                child: _TabButton(
                  tab: t,
                  active: t == tab,
                  onTap: () => onTab(t),
                ),
              ),
            const Spacer(),
            if (level != null) ...[
              BatteryRing(
                level: level,
                charging: info.charging,
                size: 15,
                stroke: 2.4,
              ),
              const SizedBox(width: 8),
            ],
            Text(
              info.timeText,
              style: const TextStyle(
                fontFamily: _textFont,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: _text,
              ),
            ),
            const SizedBox(width: 6),
            _IconAction(
              icon: pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
              color: pinned ? Palette.accentSoft : _muted,
              size: 16,
              onTap: onPin,
            ),
          ],
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.tab,
    required this.active,
    required this.onTap,
  });

  final IslandTab tab;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.centerLeft,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: EdgeInsets.symmetric(
              horizontal: active ? 10 : 7,
              vertical: 7,
            ),
            decoration: BoxDecoration(
              color: active
                  ? Palette.accent.withValues(alpha: 0.16)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  tab.icon,
                  size: 15,
                  color: active ? Palette.accentSoft : _muted,
                ),
                if (active) ...[
                  const SizedBox(width: 6),
                  Text(
                    tab.label,
                    maxLines: 1,
                    style: TextStyle(
                      fontFamily: _textFont,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Palette.accentSoft,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.tab, required this.onTab});

  final IslandTab tab;
  final ValueChanged<IslandTab> onTab;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final t in IslandTab.values)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onTab(t),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: t == tab ? 16 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: t == tab
                        ? Palette.accent
                        : Colors.white.withValues(alpha: 0.22),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ===========================================================================
// ONGLET : ACCUEIL
// ===========================================================================
class _HomeTab extends StatelessWidget {
  const _HomeTab({required this.info});

  final SystemInfo info;

  @override
  Widget build(BuildContext context) {
    final level = info.batteryLevel;

    return Padding(
      padding: const EdgeInsets.fromLTRB(34, 0, 30, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info.timeText,
                  style: const TextStyle(
                    fontFamily: _displayFont,
                    fontSize: 46,
                    fontWeight: FontWeight.w300,
                    letterSpacing: -1.5,
                    height: 1.0,
                    color: _text,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  info.dateText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: _textFont,
                    fontSize: 13,
                    letterSpacing: 0.1,
                    color: _muted,
                  ),
                ),
              ],
            ),
          ),
          if (level != null)
            BatteryRing(
              level: level,
              charging: info.charging,
              size: 64,
              stroke: 5.5,
              showLabel: true,
            ),
        ],
      ),
    );
  }
}

// ===========================================================================
// ONGLET : MUSIQUE
// ===========================================================================
String _fmtTime(double seconds) {
  final int s = (seconds.isNaN || seconds < 0) ? 0 : seconds.floor();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final r = (s % 60).toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$r';
  return '$m:$r';
}

/// Nom lisible de l'appli qui joue le média, à partir de l'identifiant Windows.
String _friendlyApp(String id) {
  final lower = id.toLowerCase();
  if (lower.isEmpty) return '';
  if (lower.contains('chrome')) return 'Chrome';
  if (lower.contains('msedge') || lower.contains('edge')) return 'Edge';
  if (lower.contains('firefox')) return 'Firefox';
  if (lower.contains('brave')) return 'Brave';
  if (lower.contains('opera')) return 'Opera';
  if (lower.contains('spotify')) return 'Spotify';
  if (lower.contains('applemusic') || lower.contains('itunes')) return 'Apple Music';
  if (lower.contains('vlc')) return 'VLC';
  final base = id.split(RegExp(r'[\\/!]')).last.replaceAll(RegExp(r'\.exe$', caseSensitive: false), '');
  return base.isEmpty ? '' : '${base[0].toUpperCase()}${base.substring(1)}';
}

class _MusicTab extends StatefulWidget {
  const _MusicTab({required this.store});

  final MediaStore store;

  @override
  State<_MusicTab> createState() => _MusicTabState();
}

class _MusicTabState extends State<_MusicTab> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Fait avancer la barre de progression et les paroles en douceur.
    _timer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (mounted && widget.store.playing) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;

    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        if (!store.bridgeFound) {
          return const _EmptyHint(
            'Composant média introuvable.\n'
            'Compilez le dossier media_bridge (voir les instructions).',
          );
        }
        if (!store.active) {
          return const _EmptyHint(
            'Aucun média en lecture.\n'
            'Lancez Spotify, YouTube ou Apple Music.',
          );
        }
        if (store.lyricsWanted) return _LyricsView(store: store);
        return _PlayerView(store: store);
      },
    );
  }
}

class _PlayerView extends StatelessWidget {
  const _PlayerView({required this.store});

  final MediaStore store;

  @override
  Widget build(BuildContext context) {
    final pos = store.position;
    final dur = store.duration;
    final hasTimeline = dur > 0;
    final frac = hasTimeline ? (pos / dur).clamp(0.0, 1.0).toDouble() : 0.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 6, 22, 0),
      child: Row(
        children: [
          _Cover(art: store.art, size: 88, radius: 18),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  store.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: _textFont,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: _text,
                  ),
                ),
                Text(
                  store.artist.isNotEmpty
                      ? store.artist
                      : _friendlyApp(store.app),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: _textFont,
                    fontSize: 12,
                    color: _muted,
                  ),
                ),
                const SizedBox(height: 6),
                if (hasTimeline)
                Row(
                  children: [
                    SizedBox(
                      width: 44,
                      child: Text(
                        _fmtTime(pos),
                        maxLines: 1,
                        softWrap: false,
                        style: const TextStyle(
                          fontFamily: _textFont,
                          fontSize: 10.5,
                          color: _muted,
                        ),
                      ),
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, c) {
                          return MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapDown: dur > 0
                                  ? (d) => store.seek(
                                        d.localPosition.dx / c.maxWidth * dur,
                                      )
                                  : null,
                              child: SizedBox(
                                height: 14,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Stack(
                                    children: [
                                      Container(
                                        height: 4,
                                        width: c.maxWidth,
                                        decoration: BoxDecoration(
                                          color: Colors.white
                                              .withValues(alpha: 0.16),
                                          borderRadius:
                                              BorderRadius.circular(2),
                                        ),
                                      ),
                                      Container(
                                        height: 4,
                                        width: c.maxWidth * frac,
                                        decoration: BoxDecoration(
                                          color: Palette.accent,
                                          borderRadius:
                                              BorderRadius.circular(2),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    SizedBox(
                      width: 50,
                      child: Text(
                        '-${_fmtTime(dur - pos)}',
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        softWrap: false,
                        style: const TextStyle(
                          fontFamily: _textFont,
                          fontSize: 10.5,
                          color: _muted,
                        ),
                      ),
                    ),
                  ],
                )
                else
                  const _StreamingLabel(),
                const SizedBox(height: 4),
                Row(
                  children: [
                    _IconAction(
                      icon: Icons.skip_previous_rounded,
                      color: _text,
                      size: 24,
                      onTap: store.previous,
                    ),
                    const SizedBox(width: 6),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: store.playPause,
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: const BoxDecoration(
                            color: _text,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            store.playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 24,
                            color: Palette.bg,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _IconAction(
                      icon: Icons.skip_next_rounded,
                      color: _text,
                      size: 24,
                      onTap: store.next,
                    ),
                    const Spacer(),
                    _IconAction(
                      icon: Icons.lyrics_rounded,
                      color: _muted,
                      size: 19,
                      onTap: () => store.setLyricsWanted(true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Affiché à la place de la barre de progression quand le média n'a pas de
/// durée (direct, vidéo en continu...).
class _StreamingLabel extends StatelessWidget {
  const _StreamingLabel();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 14,
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: _alert,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          const Text(
            'En continu',
            style: TextStyle(
              fontFamily: _textFont,
              fontSize: 10.5,
              color: _muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _LyricsView extends StatelessWidget {
  const _LyricsView({required this.store});

  final MediaStore store;

  int _currentIndex() {
    final pos = store.position + 0.3;
    var idx = -1;
    for (var i = 0; i < store.lyrics.length; i++) {
      if (store.lyrics[i].time <= pos) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  String _lineAt(int i) =>
      (i < 0 || i >= store.lyrics.length) ? '' : store.lyrics[i].text;

  @override
  Widget build(BuildContext context) {
    Widget body;

    switch (store.lyricsState) {
      case LyricsState.idle:
      case LyricsState.loading:
        body = const Text(
          'Recherche des paroles…',
          style: TextStyle(fontFamily: _textFont, fontSize: 12.5, color: _muted),
        );
      case LyricsState.missing:
        body = const Text(
          'Paroles synchronisées introuvables pour ce titre.',
          textAlign: TextAlign.center,
          style: TextStyle(fontFamily: _textFont, fontSize: 12.5, color: _muted),
        );
      case LyricsState.ready:
        final idx = _currentIndex();
        final current = idx >= 0 ? _lineAt(idx) : '♪';
        body = AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: Column(
            key: ValueKey(idx),
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _lineAt(idx - 1),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: _textFont,
                  fontSize: 12,
                  color: _muted.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                current,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: _textFont,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                  color: _text,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                _lineAt(idx + 1),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: _textFont,
                  fontSize: 12,
                  color: _muted.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 4, 22, 0),
      child: Column(
        children: [
          Row(
            children: [
              _Cover(art: store.art, size: 36, radius: 10),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      store.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: _textFont,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _text,
                      ),
                    ),
                    Text(
                      store.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: _textFont,
                        fontSize: 11.5,
                        color: _muted,
                      ),
                    ),
                  ],
                ),
              ),
              _IconAction(
                icon: Icons.close_rounded,
                color: _muted,
                size: 18,
                onTap: () => store.setLyricsWanted(false),
              ),
            ],
          ),
          Expanded(child: Center(child: body)),
        ],
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.art, required this.size, required this.radius});

  final Uint8List? art;
  final double size;
  final double radius;

  Widget _placeholder() => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Palette.accent, Palette.accent.withValues(alpha: 0.5)],
          ),
        ),
        child: Center(
          child: Icon(Icons.music_note_rounded, size: size * 0.45, color: Palette.bg),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: art == null
            ? _placeholder()
            : Image.memory(
                art!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: (size * 2).round(),
                errorBuilder: (_, __, ___) => _placeholder(),
              ),
      ),
    );
  }
}

// ===========================================================================
// ONGLET : PRESSE-PAPIERS
// ===========================================================================
class _ClipboardTab extends StatelessWidget {
  const _ClipboardTab({required this.store});

  final ClipboardStore store;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final items = store.items;

        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 4, 22, 0),
          child: Column(
            children: [
              SizedBox(
                height: 20,
                child: Row(
                  children: [
                    const Text(
                      'Historique',
                      style: TextStyle(
                        fontFamily: _textFont,
                        fontSize: 11.5,
                        color: _muted,
                      ),
                    ),
                    const Spacer(),
                    if (items.isNotEmpty)
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: store.clear,
                          child: Text(
                            'Vider',
                            style: TextStyle(
                              fontFamily: _textFont,
                              fontSize: 11.5,
                              color: Palette.accentSoft,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: items.isEmpty
                    ? const _EmptyHint(
                        'Rien copié pour l\'instant.\n'
                        'Copiez du texte avec Ctrl+C, il apparaîtra ici.',
                      )
                    : ListView.separated(
                        padding: EdgeInsets.zero,
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 5),
                        itemBuilder: (context, i) => _ClipRow(
                          key: ValueKey(items[i]),
                          text: items[i],
                          onCopy: () => store.copy(items[i]),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ClipRow extends StatefulWidget {
  const _ClipRow({super.key, required this.text, required this.onCopy});

  final String text;
  final VoidCallback onCopy;

  @override
  State<_ClipRow> createState() => _ClipRowState();
}

class _ClipRowState extends State<_ClipRow> {
  bool _copied = false;
  Timer? _timer;

  void _tap() {
    widget.onCopy();
    setState(() => _copied = true);
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final oneLine = widget.text.replaceAll(RegExp(r'\s+'), ' ').trim();

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _tap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  oneLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: _textFont,
                    fontSize: 12.5,
                    color: _text,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                _copied ? Icons.check_rounded : Icons.copy_rounded,
                size: 14,
                color: _copied ? _mint : _muted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// ONGLET : À FAIRE
// ===========================================================================
class _TodoTab extends StatefulWidget {
  const _TodoTab({required this.store});

  final TodoStore store;

  @override
  State<_TodoTab> createState() => _TodoTabState();
}

class _TodoTabState extends State<_TodoTab> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  void _submit([String? _]) {
    widget.store.add(_controller.text);
    _controller.clear();
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final items = widget.store.items;
        final done = widget.store.doneCount;

        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 4, 22, 0),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: TextField(
                        controller: _controller,
                        focusNode: _focus,
                        onSubmitted: _submit,
                        cursorColor: Palette.accent,
                        style: const TextStyle(
                          fontFamily: _textFont,
                          fontSize: 13,
                          color: _text,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Nouvelle tâche',
                          hintStyle: const TextStyle(
                            fontFamily: _textFont,
                            fontSize: 13,
                            color: _muted,
                          ),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.07),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: _submit,
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: Palette.accent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.add_rounded,
                          size: 20,
                          color: Palette.bg,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(
                height: 22,
                child: Row(
                  children: [
                    Text(
                      items.isEmpty ? '' : '$done sur ${items.length} terminées',
                      style: const TextStyle(
                        fontFamily: _textFont,
                        fontSize: 11.5,
                        color: _muted,
                      ),
                    ),
                    const Spacer(),
                    if (done > 0)
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: widget.store.clearDone,
                          child: Text(
                            'Effacer les terminées',
                            style: TextStyle(
                              fontFamily: _textFont,
                              fontSize: 11.5,
                              color: Palette.accentSoft,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: items.isEmpty
                    ? const _EmptyHint(
                        'Aucune tâche.\nÉcrivez-en une puis appuyez sur Entrée.',
                      )
                    : ListView.builder(
                        padding: EdgeInsets.zero,
                        itemCount: items.length,
                        itemBuilder: (context, i) => _TodoRow(
                          key: ObjectKey(items[i]),
                          item: items[i],
                          store: widget.store,
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TodoRow extends StatelessWidget {
  const _TodoRow({super.key, required this.item, required this.store});

  final TodoItem item;
  final TodoStore store;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => store.toggle(item),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: item.done ? Palette.accent : Colors.transparent,
                  border: Border.all(
                    color: item.done ? Palette.accent : _muted.withValues(alpha: 0.7),
                    width: 1.6,
                  ),
                ),
                child: item.done
                    ? Icon(Icons.check_rounded, size: 12, color: Palette.bg)
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: _textFont,
                    fontSize: 13,
                    color: item.done ? _muted : _text,
                    decoration:
                        item.done ? TextDecoration.lineThrough : null,
                    decorationColor: _muted,
                  ),
                ),
              ),
              _IconAction(
                icon: Icons.close_rounded,
                color: _muted,
                size: 15,
                onTap: () => store.remove(item),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// ONGLET : MINUTEUR
// ===========================================================================
class _TimerTab extends StatelessWidget {
  const _TimerTab({required this.store});

  final TimerStore store;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final color = store.isBreak ? _mint : Palette.accent;
        final canAdjust =
            !store.running && store.remainingSeconds == store.totalSeconds;
        final dim = _muted.withValues(alpha: 0.4);

        return Padding(
          padding: const EdgeInsets.fromLTRB(34, 2, 30, 4),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 98,
                child: CustomPaint(
                  painter: _RingPainter(
                    progress: store.progress,
                    color: color,
                    track: Colors.white.withValues(alpha: 0.12),
                    stroke: 6,
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _fmtClock(store.remainingSeconds),
                          style: const TextStyle(
                            fontFamily: _displayFont,
                            fontSize: 25,
                            fontWeight: FontWeight.w300,
                            letterSpacing: -0.5,
                            height: 1.0,
                            color: _text,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          store.kind == TimerKind.longBreak
                              ? 'Pause longue'
                              : store.kind.label,
                          style: const TextStyle(
                            fontFamily: _textFont,
                            fontSize: 11,
                            color: _muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 26),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        for (final k in TimerKind.values)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: _Chip(
                              label: k.label,
                              selected: k == store.kind,
                              onTap: () => store.select(k),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        _IconAction(
                          icon: Icons.remove_rounded,
                          color: canAdjust ? _text : dim,
                          size: 20,
                          onTap: () => store.adjustMinutes(-5),
                        ),
                        const SizedBox(width: 6),
                        MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            onTap: store.toggle,
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: color,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                store.running
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                size: 26,
                                color: Palette.bg,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        _IconAction(
                          icon: Icons.add_rounded,
                          color: canAdjust ? _text : dim,
                          size: 20,
                          onTap: () => store.adjustMinutes(5),
                        ),
                        const Spacer(),
                        _IconAction(
                          icon: Icons.restart_alt_rounded,
                          color: _muted,
                          size: 20,
                          onTap: store.reset,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            color: selected
                ? Palette.accent.withValues(alpha: 0.16)
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: _textFont,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: selected ? Palette.accentSoft : _muted,
            ),
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// MINI-NOTIFICATION
// ===========================================================================
class _PeekContent extends StatelessWidget {
  const _PeekContent({required this.peek});

  final IslandPeek peek;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 22, 0),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 36,
            child: CustomPaint(
              painter: _RingPainter(
                progress: peek.progress ?? 1.0,
                color: peek.color,
                track: peek.color.withValues(alpha: 0.22),
                stroke: 3.5,
              ),
              child: Center(
                child: Icon(peek.icon, size: 17, color: peek.color),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  peek.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: _textFont,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _text,
                  ),
                ),
                Text(
                  peek.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: _textFont,
                    fontSize: 11.5,
                    color: _muted,
                  ),
                ),
              ],
            ),
          ),
          if (peek.trailing != null) ...[
            const SizedBox(width: 8),
            Text(
              peek.trailing!,
              style: TextStyle(
                fontFamily: _displayFont,
                fontSize: 21,
                fontWeight: FontWeight.w600,
                color: peek.color,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ===========================================================================
// ONGLET : RÉGLAGES
// ===========================================================================
class _SettingsTab extends StatelessWidget {
  const _SettingsTab({required this.store});

  final SettingsStore store;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final sep = Platform.pathSeparator;
        final devBuild = Platform.resolvedExecutable
            .toLowerCase()
            .contains('${sep}debug$sep');

        return ListView(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 6),
          children: [
            const _SectionLabel('Mini-notifications'),
            _SwitchRow(
              label: 'Batterie du PC',
              value: store.notifBattery,
              onChanged: store.setNotifBattery,
            ),
            _SwitchRow(
              label: 'Minuteur terminé',
              value: store.notifTimer,
              onChanged: store.setNotifTimer,
            ),
            _SwitchRow(
              label: 'Casque Bluetooth et sa batterie',
              value: store.notifBluetooth,
              onChanged: store.setNotifBluetooth,
            ),
            const _SectionLabel('Affichage'),
            _SwitchRow(
              label: 'Masquer en plein écran',
              value: store.hideInFullscreen,
              onChanged: store.setHideInFullscreen,
            ),
            _SwitchRow(
              label: "Couleurs du fond d'écran",
              value: store.followWallpaper,
              onChanged: store.setFollowWallpaper,
            ),
            if (!store.followWallpaper)
              _AccentPicker(
                selected: store.manualAccent,
                onPick: store.setManualAccent,
              ),
            _StepperRow(
              label: "Distance au bord de l'écran",
              value: '${store.topGap.round()} px',
              onMinus: () => store.adjustTopGap(-2),
              onPlus: () => store.adjustTopGap(2),
            ),
            const _SectionLabel('Système'),
            _SwitchRow(
              label: 'Lancer avec Windows',
              value: store.autoStart,
              enabled: store.autoStartAvailable,
              onChanged: store.setAutoStart,
            ),
            if (devBuild)
              const _Hint(
                'Version de développement : pour le lancement automatique, '
                'active plutôt cette option depuis la version finale '
                '(flutter build windows --release).',
              ),
            if (!store.autoStartAvailable)
              const _Hint('Lancement automatique indisponible sur ce PC.'),
          ],
        );
      },
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 2),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontFamily: _textFont,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: _muted,
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: _textFont,
          fontSize: 10.5,
          height: 1.35,
          color: _muted,
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => onChanged(!value) : null,
        child: SizedBox(
          height: 34,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: _textFont,
                    fontSize: 13,
                    color: enabled ? _text : _muted,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _Toggle(value: value, enabled: enabled),
            ],
          ),
        ),
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.value, this.enabled = true});

  final bool value;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: 38,
      height: 22,
      padding: const EdgeInsets.all(3),
      alignment: value ? Alignment.centerRight : Alignment.centerLeft,
      decoration: BoxDecoration(
        color: value
            ? Palette.accent.withValues(alpha: enabled ? 1.0 : 0.4)
            : Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: value ? Palette.bg : _text,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _StepperRow extends StatelessWidget {
  const _StepperRow({
    required this.label,
    required this.value,
    required this.onMinus,
    required this.onPlus,
  });

  final String label;
  final String value;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: _textFont,
                fontSize: 13,
                color: _text,
              ),
            ),
          ),
          _IconAction(
            icon: Icons.remove_rounded,
            color: _text,
            size: 18,
            onTap: onMinus,
          ),
          SizedBox(
            width: 46,
            child: Text(
              value,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: _textFont,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: _text,
              ),
            ),
          ),
          _IconAction(
            icon: Icons.add_rounded,
            color: _text,
            size: 18,
            onTap: onPlus,
          ),
        ],
      ),
    );
  }
}

class _AccentPicker extends StatelessWidget {
  const _AccentPicker({required this.selected, required this.onPick});

  final int selected;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          for (final c in _manualAccents)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => onPick(c.toARGB32()),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: c.toARGB32() == selected
                          ? _text
                          : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ===========================================================================
// PETITS COMPOSANTS PARTAGÉS
// ===========================================================================
class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontFamily: _textFont,
          fontSize: 12,
          height: 1.45,
          color: _muted,
        ),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.color,
    required this.onTap,
    this.size = 24,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, color: color, size: size),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Anneau de batterie dessiné à la main (CustomPainter)
// ---------------------------------------------------------------------------
class BatteryRing extends StatelessWidget {
  const BatteryRing({
    super.key,
    required this.level,
    required this.charging,
    required this.size,
    required this.stroke,
    this.showLabel = false,
  });

  final int level;
  final bool charging;
  final double size;
  final double stroke;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final color = batteryRingColor(level, charging);

    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _RingPainter(
          progress: level / 100,
          color: color,
          track: Colors.white.withValues(alpha: 0.14),
          stroke: stroke,
        ),
        child: showLabel
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (charging)
                      Icon(Icons.bolt_rounded, size: 12, color: color),
                    Text(
                      '$level',
                      style: const TextStyle(
                        fontFamily: _displayFont,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        height: 1.05,
                        color: _text,
                      ),
                    ),
                  ],
                ),
              )
            : null,
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.color,
    required this.track,
    required this.stroke,
  });

  final double progress;
  final Color color;
  final Color track;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - stroke) / 2;

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = track;

    final valuePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;

    canvas.drawCircle(center, radius, trackPaint);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress.clamp(0.0, 1.0),
      false,
      valuePaint,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.track != track ||
      old.stroke != stroke;
}