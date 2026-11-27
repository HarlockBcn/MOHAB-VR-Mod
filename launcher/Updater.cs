using System.Diagnostics;
using System.IO.Compression;
using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;

namespace MOHABPlus;

internal sealed record ReleaseInfo(Version Version, string Tag, string Name, string Notes, string PageUrl, string? ZipUrl, long ZipSize);

internal enum UpdateCheckState { UpToDate, UpdateAvailable, NoReleases, Failed }

internal sealed record UpdateCheckResult(UpdateCheckState State, ReleaseInfo? Release = null, string? Error = null);

/// <summary>
/// Checks the GitHub repository for a newer release and installs it in place.
/// Running files (the launcher exe/dll) cannot be overwritten but can be renamed, so every replaced file is first
/// renamed to *.mohabplus-old (removed on the next start) and the new file is copied in its place.
/// </summary>
internal static class Updater
{
    private const string OldSuffix = ".mohabplus-old";
    private const string LatestApi = "https://api.github.com/repos/" + AppInfo.RepoOwner + "/" + AppInfo.RepoName + "/releases/latest";
    private const string DownloadPrefix = AppInfo.RepoUrl + "/releases/download/";

    /// <summary>User data that an update must never overwrite (relative to the launcher folder).</summary>
    private static readonly HashSet<string> Protected = new(StringComparer.OrdinalIgnoreCase)
    {
        "launcher.ini", "launcher.log",
        Path.Combine("ue4ss", "UE4SS.log"),
        Path.Combine("ue4ss", "Mods", "MOHABPlus", "config.ini"),
        Path.Combine("ue4ss", "Mods", "MOHABPlus", "cmd.txt"),
    };

    private static HttpClient NewClient(TimeSpan timeout)
    {
        var http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = true }) { Timeout = timeout };
        http.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("MOHABPlus-Launcher", AppInfo.Version.ToString()));
        return http;
    }

    public static async Task<UpdateCheckResult> CheckAsync(CancellationToken ct = default)
    {
        try
        {
            using var http = NewClient(TimeSpan.FromSeconds(10));
            using var req = new HttpRequestMessage(HttpMethod.Get, LatestApi);
            req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
            using var resp = await http.SendAsync(req, ct);
            if (resp.StatusCode == HttpStatusCode.NotFound) return new(UpdateCheckState.NoReleases);
            if (!resp.IsSuccessStatusCode) return new(UpdateCheckState.Failed, Error: $"GitHub answered {(int)resp.StatusCode}");

            using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync(ct));
            var root = doc.RootElement;
            string tag = Str(root, "tag_name");
            var version = AppInfo.ParseTag(tag);
            if (version == null) return new(UpdateCheckState.Failed, Error: $"Unrecognised release tag '{tag}'");

            string? zipUrl = null; long zipSize = 0;
            if (root.TryGetProperty("assets", out var assets))
            {
                foreach (var a in assets.EnumerateArray())
                {
                    string name = Str(a, "name"), url = Str(a, "browser_download_url");
                    if (!name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) || !url.StartsWith(DownloadPrefix, StringComparison.OrdinalIgnoreCase)) continue;
                    bool preferred = name.StartsWith("MOHABPlus", StringComparison.OrdinalIgnoreCase);
                    if (zipUrl == null || preferred)
                    {
                        zipUrl = url;
                        zipSize = a.TryGetProperty("size", out var sz) && sz.TryGetInt64(out long l) ? l : 0;
                        if (preferred) break;
                    }
                }
            }

            var info = new ReleaseInfo(version, tag, Str(root, "name"), Str(root, "body"), Str(root, "html_url"), zipUrl, zipSize);
            return new(version > AppInfo.Version ? UpdateCheckState.UpdateAvailable : UpdateCheckState.UpToDate, info);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            return new(UpdateCheckState.Failed, Error: "timed out");
        }
        catch (HttpRequestException ex)
        {
            return new(UpdateCheckState.Failed, Error: ex.Message);
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException)
        {
            return new(UpdateCheckState.Failed, Error: "invalid answer from GitHub");
        }
    }

    private static string Str(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";

    /// <summary>Downloads the release zip and installs it over <paramref name="baseDir"/>. Throws on failure (nothing changed).</summary>
    public static async Task InstallAsync(ReleaseInfo release, string baseDir, IProgress<string> progress, CancellationToken ct = default)
    {
        if (release.ZipUrl == null) throw new InvalidOperationException("This release has no zip file attached.");
        if (ModInjectorService.FindGameProcesses().Length > 0) throw new InvalidOperationException("Close the game before updating.");

        string work = Path.Combine(Path.GetTempPath(), "MOHABPlus-update", release.Version.ToString());
        if (Directory.Exists(work)) Directory.Delete(work, true);
        Directory.CreateDirectory(work);
        string zipPath = Path.Combine(work, "release.zip");

        // Download
        using (var http = NewClient(TimeSpan.FromMinutes(10)))
        using (var resp = await http.GetAsync(release.ZipUrl, HttpCompletionOption.ResponseHeadersRead, ct))
        {
            resp.EnsureSuccessStatusCode();
            long total = resp.Content.Headers.ContentLength ?? release.ZipSize;
            await using var src = await resp.Content.ReadAsStreamAsync(ct);
            await using var dst = File.Create(zipPath);
            var buf = new byte[81920];
            long done = 0; int read, lastPct = -1;
            while ((read = await src.ReadAsync(buf, ct)) > 0)
            {
                await dst.WriteAsync(buf.AsMemory(0, read), ct);
                done += read;
                int pct = total > 0 ? (int)(done * 100 / total) : -1;
                if (pct != lastPct) { lastPct = pct; progress.Report(pct >= 0 ? Lang.T("ui.downloading", AppInfo.Format(release.Version), pct) : Lang.T("ui.downloading_kb", done / 1024)); }
            }
        }

        InstallFromZip(zipPath, baseDir, progress, ct);
        try { Directory.Delete(work, true); } catch { /* temp, not critical */ }
        progress.Report(Lang.T("ui.updated_to", AppInfo.Format(release.Version)));
    }

    /// <summary>Installs a release zip over <paramref name="baseDir"/> (user settings kept). Throws on failure, rolling back.</summary>
    public static void InstallFromZip(string zipPath, string baseDir, IProgress<string> progress, CancellationToken ct = default)
    {
        string work = Path.Combine(Path.GetTempPath(), "MOHABPlus-update", "extract-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(work);
        try { InstallFromZipCore(zipPath, work, baseDir, progress, ct); }
        finally { try { Directory.Delete(work, true); } catch { } }
    }

    private static void InstallFromZipCore(string zipPath, string work, string baseDir, IProgress<string> progress, CancellationToken ct)
    {
        // Extract (ExtractToDirectory rejects entries that would land outside the folder)
        progress.Report(Lang.T("ui.extracting"));
        string extracted = Path.Combine(work, "files");
        ZipFile.ExtractToDirectory(zipPath, extracted);
        string newRoot = FindPackageRoot(extracted)
            ?? throw new InvalidDataException("The downloaded zip does not look like a MOHAB Plus release.");

        // Install with rollback
        progress.Report(Lang.T("ui.installing"));
        var replaced = new List<string>();   // targets that were renamed to *.old
        var created = new List<string>();    // targets that did not exist before
        try
        {
            foreach (string file in Directory.EnumerateFiles(newRoot, "*", SearchOption.AllDirectories))
            {
                ct.ThrowIfCancellationRequested();
                string rel = Path.GetRelativePath(newRoot, file);
                if (Protected.Contains(rel)) continue;
                string target = Path.Combine(baseDir, rel);
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                if (File.Exists(target))
                {
                    string old = target + OldSuffix;
                    if (File.Exists(old)) File.Delete(old);
                    File.Move(target, old);
                    replaced.Add(target);
                }
                else created.Add(target);
                File.Copy(file, target);
            }
        }
        catch
        {
            foreach (string t in created) TryDelete(t);
            foreach (string t in replaced)
            {
                try { if (File.Exists(t)) File.Delete(t); File.Move(t + OldSuffix, t); } catch { /* best effort */ }
            }
            throw;
        }
    }

    /// <summary>Folder inside the extracted zip that contains the launcher and the ue4ss payload.</summary>
    private static string? FindPackageRoot(string dir)
    {
        foreach (string exe in Directory.EnumerateFiles(dir, "MOHABPlusLauncher.exe", SearchOption.AllDirectories))
        {
            string root = Path.GetDirectoryName(exe)!;
            if (File.Exists(Path.Combine(root, "ue4ss", ModInjectorService.Ue4ssDllName))) return root;
        }
        return null;
    }

    /// <summary>Starts the freshly installed launcher. The caller must exit right after.</summary>
    public static void Restart(string baseDir, Version installed)
    {
        string exe = Path.Combine(baseDir, "MOHABPlusLauncher.exe");
        Process.Start(new ProcessStartInfo(exe, "--updated " + installed) { UseShellExecute = true, WorkingDirectory = baseDir });
    }

    /// <summary>Removes files left behind by a previous update (they were locked while that launcher was running).</summary>
    public static void CleanupOldFiles(string baseDir)
    {
        try
        {
            foreach (string f in Directory.EnumerateFiles(baseDir, "*" + OldSuffix, SearchOption.AllDirectories)) TryDelete(f);
        }
        catch { /* not critical */ }
    }

    private static void TryDelete(string f) { try { File.Delete(f); } catch { } }
}
