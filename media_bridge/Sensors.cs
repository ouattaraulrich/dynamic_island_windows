// Sensors : surveille Windows et prévient l'île Flutter (une ligne JSON par événement).
//
//   {"t":"bt","name":"AirPods","connected":true}            (appareil audio Bluetooth)
//   {"t":"btbattery","name":"AirPods","level":80,"first":true}
//                                                          (batterie de cet appareil)
//   {"t":"fullscreen","active":true}                       (appli, jeu ou présentation en plein écran)
//
// Chaque capteur tourne dans sa propre tâche. S'il n'est pas disponible sur ce PC
// (pas de Bluetooth...), il s'arrête sans gêner les autres.

using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Windows.Devices.Bluetooth;
using Windows.Devices.Enumeration;

namespace MediaBridge;

internal static class Sensors
{
    // -----------------------------------------------------------------------
    // Casque / enceinte Bluetooth (appareils audio déjà jumelés)
    // -----------------------------------------------------------------------
    private sealed class BtDevice
    {
        public string Id = "";
        public string Name = "";
        public ulong Address;                       // adresse Bluetooth (sert à retrouver sa batterie)
        public DateTime LastCheck = DateTime.MinValue;
        public int Attempts;                        // lectures déjà tentées
        public int? LastLevel;                      // dernière batterie connue
    }

    private static readonly object BtGate = new();

    // Appareils audio actuellement connectés (clé : identifiant Windows de l'appareil).
    private static readonly Dictionary<string, BtDevice> BtTracked = new();

    private static DeviceWatcher? _btWatcher; // gardé pour qu'il ne soit pas ramassé

    private static bool? ReadConnected(IReadOnlyDictionary<string, object> properties)
    {
        if (properties.TryGetValue("System.Devices.Aep.IsConnected", out var value) && value is bool b)
        {
            return b;
        }
        return null;
    }

    // Est-ce un appareil audio (casque, enceinte...) ? Et quelle est son adresse ?
    private static async Task<(bool IsAudio, ulong Address)> ReadAudioInfo(string id)
    {
        try
        {
            using var device = await BluetoothDevice.FromIdAsync(id);
            if (device == null) return (true, 0);
            return (device.ClassOfDevice.MajorClass == BluetoothMajorClass.AudioVideo, device.BluetoothAddress);
        }
        catch
        {
            // Impossible de connaître le type : on laisse passer.
            return (true, 0);
        }
    }

    // Ajoute l'appareil à la liste suivie, si c'est un appareil audio.
    private static async Task TrackAsync(string id, string name, bool announce, Action<object> emit)
    {
        var (isAudio, address) = await ReadAudioInfo(id);
        if (!isAudio) return;

        lock (BtGate)
        {
            BtTracked[id] = new BtDevice { Id = id, Name = name, Address = address };
        }

        if (announce)
        {
            emit(new { t = "bt", name, connected = true });
        }
    }

    public static void StartBluetooth(Action<object> emit)
    {
        var names = new Dictionary<string, string>();
        var connected = new Dictionary<string, bool>();
        var ready = false; // vrai une fois la liste initiale des appareils lue

        var selector = BluetoothDevice.GetDeviceSelectorFromPairingState(true);
        var watcher = DeviceInformation.CreateWatcher(
            selector,
            new[] { "System.Devices.Aep.IsConnected" },
            DeviceInformationKind.AssociationEndpoint);

        // Appareils déjà connus au démarrage : on retient leur état sans rien annoncer.
        // S'ils sont déjà connectés, on les suit quand même (pour leur batterie).
        watcher.Added += (sender, info) =>
        {
            bool isOn;
            lock (BtGate)
            {
                names[info.Id] = info.Name;
                isOn = ReadConnected(info.Properties) ?? false;
                connected[info.Id] = isOn;
            }

            if (isOn)
            {
                _ = TrackAsync(info.Id, info.Name, announce: false, emit);
            }
        };

        watcher.EnumerationCompleted += (_, _) =>
        {
            lock (BtGate)
            {
                ready = true;
            }
        };

        // Un appareil se connecte ou se déconnecte.
        watcher.Updated += async (sender, update) =>
        {
            var now = ReadConnected(update.Properties);
            if (now == null) return;

            string name;
            bool changed;
            lock (BtGate)
            {
                var was = connected.TryGetValue(update.Id, out var previous) && previous;
                connected[update.Id] = now.Value;
                name = names.TryGetValue(update.Id, out var known) ? known : "Appareil Bluetooth";
                changed = ready && was != now.Value;
            }

            if (!changed) return;

            if (now.Value)
            {
                await TrackAsync(update.Id, name, announce: true, emit);
            }
            else
            {
                BtDevice? removed;
                lock (BtGate)
                {
                    BtTracked.Remove(update.Id, out removed);
                }

                // Seuls les appareils audio sont suivis : on n'annonce que ceux-là.
                if (removed != null)
                {
                    emit(new { t = "bt", name, connected = false });
                }
            }
        };

        watcher.Start();
        _btWatcher = watcher;
    }

    // -----------------------------------------------------------------------
    // Batterie des appareils Bluetooth connectés
    //
    // Windows connaît la batterie de nombreux casques et enceintes (celle qu'il
    // affiche dans les paramètres Bluetooth) mais ne la donne pas par une API
    // simple : on la lit dans les propriétés de l'appareil via PowerShell.
    // Tous les appareils ne la communiquent pas ; dans ce cas, rien n'est affiché.
    // -----------------------------------------------------------------------
    private const string BatteryScript = @"
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$key = '{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 2'
$list = @(Get-PnpDevice -Class Bluetooth | Where-Object { $_.InstanceId -like 'BTH*\DEV_*' } | ForEach-Object {
    $p = Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName $key
    if ($p -and $null -ne $p.Data) { [pscustomobject]@{ id = $_.InstanceId; battery = [int]$p.Data } }
})
ConvertTo-Json -InputObject $list -Compress
";

    private static async Task<List<(string Id, int Level)>> QueryBatteries()
    {
        var result = new List<(string Id, int Level)>();

        try
        {
            // -EncodedCommand évite tout problème de guillemets.
            var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(BatteryScript));

            var startInfo = new ProcessStartInfo("powershell.exe")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                StandardOutputEncoding = Encoding.UTF8,
            };
            startInfo.ArgumentList.Add("-NoProfile");
            startInfo.ArgumentList.Add("-NonInteractive");
            startInfo.ArgumentList.Add("-ExecutionPolicy");
            startInfo.ArgumentList.Add("Bypass");
            startInfo.ArgumentList.Add("-EncodedCommand");
            startInfo.ArgumentList.Add(encoded);

            using var process = Process.Start(startInfo);
            if (process == null) return result;

            var outputTask = process.StandardOutput.ReadToEndAsync();

            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(25));
            try
            {
                await process.WaitForExitAsync(timeout.Token);
            }
            catch (OperationCanceledException)
            {
                try { process.Kill(true); } catch { }
                return result;
            }

            var json = (await outputTask).Trim();
            if (json.Length == 0) return result;

            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            void Add(JsonElement item)
            {
                if (item.TryGetProperty("id", out var idElement) &&
                    idElement.ValueKind == JsonValueKind.String &&
                    item.TryGetProperty("battery", out var levelElement) &&
                    levelElement.TryGetInt32(out var level) &&
                    level is >= 0 and <= 100)
                {
                    result.Add((idElement.GetString() ?? "", level));
                }
            }

            if (root.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in root.EnumerateArray()) Add(item);
            }
            else if (root.ValueKind == JsonValueKind.Object)
            {
                Add(root);
            }
        }
        catch
        {
            // PowerShell indisponible ou sortie illisible : on réessaiera plus tard.
        }

        return result;
    }

    // Combien de secondes entre deux lectures de la batterie d'un appareil ?
    //  - juste après la connexion : toutes les 3 s (la valeur arrive avec un délai),
    //    pendant une trentaine de secondes ;
    //  - ensuite : toutes les 90 s si l'appareil donne sa batterie,
    //    toutes les 120 s sinon (certains ne la donnent jamais).
    private static double CheckInterval(BtDevice device)
    {
        if (device.LastLevel == null)
        {
            return device.Attempts < 10 ? 3 : 120;
        }
        return 90;
    }

    public static void StartBluetoothBattery(Action<object> emit)
    {
        Task.Run(async () =>
        {
            while (true)
            {
                try
                {
                    List<BtDevice> due;
                    lock (BtGate)
                    {
                        var now = DateTime.UtcNow;
                        due = BtTracked.Values
                            .Where(d => (now - d.LastCheck).TotalSeconds >= CheckInterval(d))
                            .ToList();
                    }

                    if (due.Count > 0)
                    {
                        // Une seule lecture pour tous les appareils.
                        var readings = await QueryBatteries();
                        var checkedAt = DateTime.UtcNow;

                        foreach (var device in due)
                        {
                            device.LastCheck = checkedAt;
                            device.Attempts++;

                            // L'adresse de l'appareil apparaît dans son identifiant : ...\DEV_AABBCCDDEEFF\...
                            var marker = "DEV_" + device.Address.ToString("X12");
                            var match = readings.FirstOrDefault(
                                r => r.Id.ToUpperInvariant().Contains(marker));
                            if (match.Id == null) continue;

                            var first = device.LastLevel == null;
                            if (first || match.Level != device.LastLevel)
                            {
                                device.LastLevel = match.Level;
                                emit(new { t = "btbattery", name = device.Name, level = match.Level, first });
                            }
                        }
                    }
                }
                catch
                {
                    // On réessaie au prochain tour.
                }

                await Task.Delay(2000);
            }
        });
    }

    // -----------------------------------------------------------------------
    // Plein écran : on demande à Windows lui-même (celui qui décide de couper
    // les notifications quand tu regardes un film, joues ou présentes).
    // -----------------------------------------------------------------------
    [DllImport("shell32.dll")]
    private static extern int SHQueryUserNotificationState(out int state);

    public static void StartFullscreen(Action<object> emit)
    {
        Task.Run(async () =>
        {
            bool? last = null;

            while (true)
            {
                try
                {
                    if (SHQueryUserNotificationState(out var state) == 0)
                    {
                        // 2 = appli plein écran, 3 = jeu Direct3D plein écran,
                        // 4 = mode présentation.
                        var active = state is 2 or 3 or 4;
                        if (last != active)
                        {
                            last = active;
                            emit(new { t = "fullscreen", active });
                        }
                    }
                }
                catch
                {
                    // On réessaie au prochain tour.
                }

                await Task.Delay(1000);
            }
        });
    }
}