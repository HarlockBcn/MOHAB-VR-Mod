using System.Diagnostics;
using System.Globalization;

namespace MOHABPlus;

internal sealed class MainForm : Form
{
    private readonly string _baseDir;
    private readonly LauncherSettings _settings;
    private readonly ModInjectorService _svc;
    private readonly ModConfig _config;

    private readonly TextBox _gameDir = new() { Dock = DockStyle.Fill };
    private readonly CheckBox _autoWatch = new() { Text = "Load the mod automatically when the game is started from Virtual Desktop / Oculus (keep this window open or minimised)", AutoSize = true };
    private readonly TextBox _log = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, Font = new Font("Consolas", 9f) };
    private readonly Dictionary<string, Control> _optionControls = new();
    private readonly NotifyIcon _tray = new();
    private FileSystemWatcher? _configWatcher;

    public MainForm(string baseDir, LauncherSettings settings)
    {
        _baseDir = baseDir;
        _settings = settings;
        _svc = new ModInjectorService(baseDir);
        _svc.Log += s => BeginInvoke(() => { _log.AppendText(s + Environment.NewLine); });
        _config = new ModConfig(Path.Combine(baseDir, "ue4ss", "Mods", "MOHABPlus", "config.ini"));
        _config.Load();

        Text = "MOHAB Plus - Medal of Honor: Above and Beyond mod launcher";
        Width = 820; Height = 640;
        StartPosition = FormStartPosition.CenterScreen;
        Icon = SystemIcons.Application;

        var tabs = new TabControl { Dock = DockStyle.Fill };
        tabs.TabPages.Add(BuildPlayTab());
        tabs.TabPages.Add(BuildSettingsTab());
        tabs.SelectedIndexChanged += (_, _) => { if (tabs.SelectedIndex == 1) { _config.Load(); RefreshOptionControls(); } };
        Controls.Add(tabs);

        _tray.Icon = Icon; _tray.Text = "MOHAB Plus"; _tray.Visible = false;
        _tray.DoubleClick += (_, _) => { Show(); WindowState = FormWindowState.Normal; _tray.Visible = false; };
        Resize += (_, _) => { if (WindowState == FormWindowState.Minimized && _svc.IsWatching) { Hide(); _tray.Visible = true; } };

        Load += (_, _) =>
        {
            if (!File.Exists(_svc.Ue4ssDll)) Append("WARNING: " + _svc.Ue4ssDll + " is missing. The ue4ss folder must be next to the launcher.");
            if (_settings.GameDir == null) Append("Game folder not found automatically. Please select it.");
            if (_autoWatch.Checked) _svc.StartWatching();
        };
        FormClosing += (_, _) => { _svc.Dispose(); _tray.Visible = false; _configWatcher?.Dispose(); };

        // Keep the settings tab in sync with changes made from the in-game menu, so "Save" never writes stale values.
        try
        {
            var dir = Path.GetDirectoryName(_config.Path)!;
            Directory.CreateDirectory(dir);
            _configWatcher = new FileSystemWatcher(dir, Path.GetFileName(_config.Path))
            {
                NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName,
                EnableRaisingEvents = true,
            };
            _configWatcher.Changed += (_, _) => BeginInvoke(ReloadConfigFromDisk);
            _configWatcher.Created += (_, _) => BeginInvoke(ReloadConfigFromDisk);
        }
        catch { /* not critical */ }
    }

    private void Append(string s) => _log.AppendText(s + Environment.NewLine);

    private TabPage BuildPlayTab()
    {
        var page = new TabPage("Play");
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 6, Padding = new Padding(10) };
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        layout.Controls.Add(new Label { Text = "Game folder:", AutoSize = true });
        var dirRow = new TableLayoutPanel { Dock = DockStyle.Top, ColumnCount = 2, AutoSize = true };
        dirRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        dirRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        _gameDir.Text = _settings.GameDir ?? "";
        var browse = new Button { Text = "Browse...", AutoSize = true };
        browse.Click += (_, _) =>
        {
            using var dlg = new FolderBrowserDialog { Description = "Select the Medal of Honor Above and Beyond folder (the one containing Mohab.exe)" };
            if (dlg.ShowDialog(this) == DialogResult.OK) { _gameDir.Text = dlg.SelectedPath; SaveLauncherSettings(); }
        };
        dirRow.Controls.Add(_gameDir, 0, 0);
        dirRow.Controls.Add(browse, 1, 0);
        layout.Controls.Add(dirRow);

        var launch = new Button { Text = "Launch game with MOHAB Plus", Height = 48, Dock = DockStyle.Top, Font = new Font(Font.FontFamily, 12f, FontStyle.Bold) };
        launch.Click += async (_, _) =>
        {
            SaveLauncherSettings();
            if (!GameLocator.IsGameDir(_gameDir.Text)) { Append("Invalid game folder."); return; }
            launch.Enabled = false;
            try { await _svc.LaunchAsync(_gameDir.Text, _settings.ExtraArgs); }
            finally { launch.Enabled = true; }
        };
        layout.Controls.Add(launch);

        _autoWatch.Checked = _settings.AutoWatch;
        _autoWatch.CheckedChanged += (_, _) =>
        {
            SaveLauncherSettings();
            if (_autoWatch.Checked) _svc.StartWatching(); else { _svc.StopWatching(); Append("Auto-load disabled."); }
        };
        layout.Controls.Add(_autoWatch);
        layout.Controls.Add(_log);

        var buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true };
        var openLog = new Button { Text = "Open UE4SS log", AutoSize = true };
        openLog.Click += (_, _) => OpenPath(Path.Combine(_baseDir, "ue4ss", "UE4SS.log"));
        var openMod = new Button { Text = "Open mod folder", AutoSize = true };
        openMod.Click += (_, _) => OpenPath(Path.Combine(_baseDir, "ue4ss", "Mods", "MOHABPlus"));
        var help = new Label
        {
            AutoSize = true, Padding = new Padding(10, 6, 0, 0),
            Text = "In game: hold LEFT Y to open the menu. Stick up/down = select, left/right = change, A/trigger = toggle, B = close.",
        };
        buttons.Controls.Add(openLog);
        buttons.Controls.Add(openMod);
        buttons.Controls.Add(help);
        layout.Controls.Add(buttons);

        page.Controls.Add(layout);
        return page;
    }

    private TabPage BuildSettingsTab()
    {
        var page = new TabPage("Mod settings");
        var outer = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2 };
        outer.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        outer.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var grid = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, AutoScroll = true, Padding = new Padding(10) };
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 60));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 40));
        string? section = null;
        foreach (var o in ModConfig.Options)
        {
            if (o.Section != section)
            {
                section = o.Section;
                var header = new Label { Text = section, AutoSize = true, Font = new Font(Font, FontStyle.Bold), Padding = new Padding(0, 8, 0, 2) };
                grid.Controls.Add(header);
                grid.SetColumnSpan(header, 2);
            }
            grid.Controls.Add(new Label { Text = o.Label, AutoSize = true, Anchor = AnchorStyles.Left, Padding = new Padding(0, 4, 0, 0) });
            Control c = o.Kind switch
            {
                OptionKind.Bool => new CheckBox { AutoSize = true },
                OptionKind.Float => new NumericUpDown
                {
                    DecimalPlaces = 2, Minimum = (decimal)o.Min, Maximum = (decimal)o.Max,
                    Increment = (decimal)o.Step, Width = 90,
                },
                _ => new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 120 },
            };
            if (c is ComboBox cb && o.Choices != null) cb.Items.AddRange(o.Choices);
            _optionControls[o.Key] = c;
            grid.Controls.Add(c);
        }
        RefreshOptionControls();

        var buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, Padding = new Padding(8) };
        var save = new Button { Text = "Save", AutoSize = true };
        save.Click += (_, _) => { ReadOptionControls(); _config.Save(); Append("Settings saved. A running game picks them up within a couple of seconds."); };
        var reload = new Button { Text = "Reload", AutoSize = true };
        reload.Click += (_, _) => { _config.Load(); RefreshOptionControls(); };
        var defaults = new Button { Text = "Defaults", AutoSize = true };
        defaults.Click += (_, _) => { foreach (var o in ModConfig.Options) _config.Values[o.Key] = o.Default; RefreshOptionControls(); };
        buttons.Controls.Add(save);
        buttons.Controls.Add(reload);
        buttons.Controls.Add(defaults);
        buttons.Controls.Add(new Label { Text = "These are the same settings as the in-game menu.", AutoSize = true, Padding = new Padding(10, 6, 0, 0) });

        outer.Controls.Add(grid);
        outer.Controls.Add(buttons);
        page.Controls.Add(outer);
        return page;
    }

    private string? _lastConfigText;
    private void ReloadConfigFromDisk()
    {
        try
        {
            string text = File.ReadAllText(_config.Path);
            if (text == _lastConfigText) return;
            _lastConfigText = text;
        }
        catch { return; }   // file being written; another event follows
        _config.Load();
        RefreshOptionControls();
    }

    private void RefreshOptionControls()
    {
        foreach (var o in ModConfig.Options)
        {
            var c = _optionControls[o.Key];
            switch (c)
            {
                case CheckBox cb: cb.Checked = _config.GetBool(o.Key); break;
                case NumericUpDown n:
                    n.Value = Math.Clamp((decimal)_config.GetFloat(o.Key), n.Minimum, n.Maximum); break;
                case ComboBox combo:
                    combo.SelectedItem = _config.Values[o.Key];
                    if (combo.SelectedIndex < 0) combo.SelectedItem = o.Default;
                    break;
            }
        }
    }

    private void ReadOptionControls()
    {
        foreach (var o in ModConfig.Options)
        {
            switch (_optionControls[o.Key])
            {
                case CheckBox cb: _config.Set(o.Key, cb.Checked); break;
                case NumericUpDown n: _config.Set(o.Key, (double)n.Value); break;
                case ComboBox combo: _config.Set(o.Key, combo.SelectedItem?.ToString() ?? o.Default); break;
            }
        }
    }

    private void SaveLauncherSettings()
    {
        _settings.GameDir = _gameDir.Text.Trim();
        _settings.AutoWatch = _autoWatch.Checked;
        try { _settings.Save(); } catch (Exception ex) { Append("Could not save launcher.ini: " + ex.Message); }
    }

    private void OpenPath(string path)
    {
        if (!File.Exists(path) && !Directory.Exists(path)) { Append("Not found: " + path); return; }
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    }
}
