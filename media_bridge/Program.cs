// media_bridge : petit programme qui fait le lien entre Windows et l'île Flutter.
//
//   Sortie (stdout), une ligne JSON par message :
//     {"t":"media","active":true,"title":"...","artist":"...","album":"...",
//      "playing":true,"pos":12.3,"dur":201.0,"app":"Spotify.exe"}
//     {"t":"media","active":false}
//     {"t":"art","key":"titre|artiste","data":"<image en base64>"}
//   et, depuis Sensors.cs : bt, btbattery, fullscreen.
//
//   Entrée (stdin), une commande par ligne :
//     play_pause | next | prev | seek:<secondes>

using System.Globalization;
using System.Text;
using System.Text.Json;
using MediaBridge;
using Windows.Media.Control;
using Windows.Storage.Streams;

var utf8 = new UTF8Encoding(false);
var stdout = new StreamWriter(Console.OpenStandardOutput(), utf8) { AutoFlush = true };
var stdin = new StreamReader(Console.OpenStandardInput(), utf8);

// Plusieurs tâches écrivent sur la même sortie : on verrouille pour ne jamais
// mélanger deux lignes.
void Emit(object message)
{
    var json = JsonSerializer.Serialize(message);
    lock (stdout)
    {
        stdout.WriteLine(json);
    }
}

var manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();

// --- Autres capteurs (casque Bluetooth, plein écran) ---------------------------
// Chacun est démarré à part : si l'un n'est pas disponible sur ce PC, les
// autres continuent de fonctionner.
static void TryStart(Action start)
{
    try
    {
        start();
    }
    catch
    {
        // Capteur indisponible : on l'ignore.
    }
}

TryStart(() => Sensors.StartBluetooth(Emit));
TryStart(() => Sensors.StartBluetoothBattery(Emit));
TryStart(() => Sensors.StartFullscreen(Emit));

// --- Commandes envoyées par Flutter ----------------------------------------
_ = Task.Run(async () =>
{
    string? line;
    while ((line = await stdin.ReadLineAsync()) != null)
    {
        try
        {
            await HandleCommand(manager, line.Trim());
        }
        catch
        {
            // Une commande qui échoue ne doit pas arrêter le pont.
        }
    }

    // Flutter a fermé le flux (application quittée) : on s'arrête aussi.
    Environment.Exit(0);
});

// --- Surveillance du média en cours ----------------------------------------
var lastKey = "";
var lastPlaying = false;
var lastActive = false;
var firstTick = true;
var lastPos = -100.0;
var lastEmit = DateTime.MinValue;
var artSent = false;
var artTries = 0;

while (true)
{
    try
    {
        var session = manager.GetCurrentSession();

        if (session == null)
        {
            if (lastActive || firstTick)
            {
                Emit(new { t = "media", active = false });
                lastActive = false;
            }
        }
        else
        {
            var props = await session.TryGetMediaPropertiesAsync();
            var timeline = session.GetTimelineProperties();
            var playback = session.GetPlaybackInfo();

            var title = props.Title ?? "";
            var artist = props.Artist ?? "";
            var key = $"{title}|{artist}";

            var playing = playback.PlaybackStatus ==
                          GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;

            var dur = Math.Max(0, (timeline.EndTime - timeline.StartTime).TotalSeconds);
            var pos = (timeline.Position - timeline.StartTime).TotalSeconds;

            // La position fournie date de "LastUpdatedTime" : on ajoute le temps écoulé.
            if (playing)
            {
                var elapsed = (DateTimeOffset.Now - timeline.LastUpdatedTime).TotalSeconds;
                if (elapsed >= 0 && elapsed < 7200) pos += elapsed;
            }

            pos = dur > 0 ? Math.Clamp(pos, 0, dur) : Math.Max(0, pos);

            var keyChanged = key != lastKey;
            if (keyChanged)
            {
                artSent = false;
                artTries = 0;
            }

            var now = DateTime.UtcNow;
            var shouldEmit =
                !lastActive ||
                keyChanged ||
                playing != lastPlaying ||
                (playing && (now - lastEmit).TotalMilliseconds >= 1000) ||
                (!playing && Math.Abs(pos - lastPos) > 0.5);

            if (shouldEmit)
            {
                Emit(new
                {
                    t = "media",
                    active = true,
                    title,
                    artist,
                    album = props.AlbumTitle ?? "",
                    playing,
                    pos,
                    dur,
                    app = session.SourceAppUserModelId ?? ""
                });
                lastEmit = now;
            }

            // La pochette peut arriver un peu après le titre : on réessaie quelques fois.
            if (!artSent && artTries < 12)
            {
                artTries++;
                var data = await ReadThumbnail(props.Thumbnail);
                if (data != null)
                {
                    Emit(new { t = "art", key, data });
                    artSent = true;
                }
            }

            lastKey = key;
            lastPlaying = playing;
            lastActive = true;
            lastPos = pos;
        }

        firstTick = false;
    }
    catch
    {
        // Session qui disparaît pendant la lecture, etc. : on réessaie au prochain tour.
    }

    await Task.Delay(400);
}

// ---------------------------------------------------------------------------
static async Task HandleCommand(
    GlobalSystemMediaTransportControlsSessionManager manager,
    string cmd)
{
    var session = manager.GetCurrentSession();
    if (session == null) return;

    if (cmd == "play_pause")
    {
        await session.TryTogglePlayPauseAsync();
    }
    else if (cmd == "next")
    {
        await session.TrySkipNextAsync();
    }
    else if (cmd == "prev")
    {
        await session.TrySkipPreviousAsync();
    }
    else if (cmd.StartsWith("seek:") &&
             double.TryParse(cmd[5..], NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds))
    {
        // Windows attend la position en "ticks" de 100 ns.
        await session.TryChangePlaybackPositionAsync((long)(seconds * 10_000_000));
    }
}

static async Task<string?> ReadThumbnail(IRandomAccessStreamReference? reference)
{
    if (reference == null) return null;

    using var stream = await reference.OpenReadAsync();
    if (stream.Size == 0 || stream.Size > 2_000_000) return null;

    var bytes = new byte[stream.Size];
    using var reader = new DataReader(stream);
    await reader.LoadAsync((uint)stream.Size);
    reader.ReadBytes(bytes);

    return Convert.ToBase64String(bytes);
}