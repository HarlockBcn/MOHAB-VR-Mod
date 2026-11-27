using System.Diagnostics;

namespace MOHABPlus;

internal sealed class MainForm : Form
{
    private readonly string _baseDir;
    private readonly LauncherSettings _settings;
    private readonly ModInjectorService _svc;
    private readonly ModConfig _config;
    private readonly bool _justUpdated;

    private readonly TextBox _gameDir = new() { Dock = DockStyle.Fill };
    private readonly ModernCheck _autoWatch = new() { Text = Lang.T("ui.auto_watch") };
    private readonly ToolTip _tips = new();
    private readonly Label _watchStatus = Theme.Label("", Theme.Bold);
    private readonly TextBox _log = new()
    {
        Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill,
        Font = Theme.Mono, BorderStyle = BorderStyle.None, BackColor = Theme.Surface, ForeColor = Theme.Text,
    };
    private readonly Dictionary<string, Control> _optionControls = new();
    private readonly NotifyIcon _tray = new();
    private FileSystemWatcher? _configWatcher;

    // Update UI
    private readonly Panel _updateBar = new() { Dock = DockStyle.Top, Visible = false, BackColor = Theme.UpdateBg };
    private readonly Label _updateText = Theme.Label("", Theme.Bold);
    private readonly ModernButton _updateNow = new(Lang.T("ui.update_now"), primary: true);
    private readonly ModernButton _updateNotes = new(Lang.T("ui.whats_new"));
    private readonly ModernButton _updateLater = new(Lang.T("ui.later"));
    private readonly LinkLabel _updateStatus = new() { AutoSize = true, Font = Theme.Small, BackColor = Color.Transparent };
    private ReleaseInfo? _available;
    private bool _checking, _installing;

    public MainForm(string baseDir, LauncherSettings settings, bool justUpdated = false)
    {
        _baseDir = baseDir;
        _settings = settings;
        _justUpdated = justUpdated;
        _svc = new ModInjectorService(baseDir);
        _svc.Log += s => BeginInvoke(() => { _log.AppendText(s + Environment.NewLine); });
        _config = new ModConfig(Path.Combine(baseDir, "ue4ss", "Mods", "MOHABPlus", "config.ini"));
        _config.Load();
        Lang.SetLanguage(Lang.Resolve(_config.Values[ModConfig.LanguageKey]));

        using (var g = CreateGraphics()) Theme.Dpi = g.DpiX / 96f;
        AutoScaleMode = AutoScaleMode.None;
        ClientSize = new Size(Theme.S(900), Theme.S(800));
        MinimumSize = new Size(Theme.S(800), Theme.S(700));
        StartPosition = FormStartPosition.CenterScreen;
        Icon = Theme.LoadIcon();
        BackColor = Theme.Bg;
        ForeColor = Theme.Text;
        Font = Theme.Body;

        InitControls();
        BuildUi();

        _tray.Icon = Icon; _tray.Text = $"MOHAB Plus {AppInfo.VersionText} {AppInfo.Credit}"; _tray.Visible = false;
        // Minimised while auto-load is on = keep running in the tray. Windows 11 often tucks new tray icons away in the
        // overflow (^), so say so the first time and offer an explicit Exit (menu built in BuildUi).
        _tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) RestoreFromTray(); };
        _tray.BalloonTipClicked += (_, _) => RestoreFromTray();
        Resize += (_, _) =>
        {
            if (WindowState != FormWindowState.Minimized || !_svc.IsWatching) return;
            Hide();
            _tray.Visible = true;
            if (!_trayHintShown)
            {
                _trayHintShown = true;
                _tray.ShowBalloonTip(6000, Lang.T("ui.tray_hint_title"), Lang.T("ui.tray_hint"), ToolTipIcon.Info);
            }
        };

        Load += async (_, _) =>
        {
            if (_justUpdated) Append(Lang.T("ui.just_updated", AppInfo.VersionText));
            if (!File.Exists(_svc.Ue4ssDll)) Append(Lang.T("ui.ue4ss_missing", _svc.Ue4ssDll));
            if (_settings.GameDir == null) Append(Lang.T("ui.game_not_found"));
            if (_autoWatch.Checked) _svc.StartWatching();
            UpdateWatchStatus();
            await CheckForUpdatesAsync(manual: false);
        };
        FormClosing += (_, _) => { _svc.Dispose(); _tray.Visible = false; _tray.Dispose(); _configWatcher?.Dispose(); };

        // Keep the settings page in sync with changes made from the in-game menu, so "Save" never writes stale values.
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

    // ---------------------------------------------------------------- Window and language

    // Controls that outlive a language change (their state is kept): set up once here, placed again by BuildUi.
    private void InitControls()
    {
        // Play page
        Theme.Style(_gameDir);
        _gameDir.Text = _settings.GameDir ?? "";
        _gameDir.Leave += (_, _) => SaveLauncherSettings();
        _autoWatch.Checked = _settings.AutoWatch;
        _autoWatch.CheckedChanged += (_, _) =>
        {
            SaveLauncherSettings();
            if (_autoWatch.Checked) _svc.StartWatching(); else { _svc.StopWatching(); Append(Lang.T("ui.auto_watch_disabled")); }
            UpdateWatchStatus();
        };
        Theme.DarkScrollBars(_log);

        // Settings page
        _basicButton.Click += (_, _) => SwitchView("basic");
        _advancedButton.Click += (_, _) => SwitchView("advanced");
        _defaultsButton.Click += (_, _) =>
        {
            // Every option, also the ones the basic view hides; the view and the language stay.
            foreach (var o in ModConfig.Options)
                if (!ModConfig.HasOwnControl(o.Key)) _config.Values[o.Key] = o.Default;
            RefreshOptionControls();
        };
        _optionGrid.ColumnCount = 2;
        _optionGrid.AutoScroll = true;
        _optionGrid.BackColor = Theme.Surface;
        _optionGrid.Padding = new Padding(Theme.S(14), Theme.S(4), Theme.S(14), Theme.S(10));
        _optionGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        _optionGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, Theme.S(170)));
        _optionGrid.Scroll += (_, _) => HideInfo();
        _optionGrid.MouseWheel += (_, _) => HideInfo();
        Theme.DarkScrollBars(_optionGrid);
        Deactivate += (_, _) => HideInfo();
        Application.AddMessageFilter(new ClickOutsideFilter(this));

        // Top bar: update status and language picker
        _updateStatus.LinkColor = Theme.Muted; _updateStatus.ActiveLinkColor = Theme.Accent; _updateStatus.VisitedLinkColor = Theme.Muted;
        _updateStatus.LinkBehavior = LinkBehavior.HoverUnderline;
        _updateStatus.Dock = DockStyle.Right;
        _updateStatus.TextAlign = ContentAlignment.MiddleRight;
        _updateStatus.AutoSize = false;
        _updateStatus.Width = Theme.S(320);
        _updateStatus.LinkClicked += async (_, _) =>
        {
            if (_available != null) ShowReleaseNotes(_available);
            else await CheckForUpdatesAsync(manual: true);
        };
        _languageBox.SelectedIndexChanged += (_, _) =>
        {
            if (_buildingUi || _languageBox.SelectedIndex < 0) return;
            string code = _languageCodes[_languageBox.SelectedIndex];
            if (code != _config.Values[ModConfig.LanguageKey]) BeginInvoke(() => SwitchLanguage(code));
        };

        BuildUpdateBar();
    }

    private Control? _content, _nav, _banner, _footer;
    private ContextMenuStrip? _trayMenu;
    private bool _buildingUi;
    private int _page;   // page shown (kept across language changes)
    private readonly ComboBox _languageBox = new()
    {
        DropDownStyle = ComboBoxStyle.DropDownList, FlatStyle = FlatStyle.Flat, Width = Theme.S(170),
        BackColor = Theme.Surface2, ForeColor = Theme.Text, Font = Theme.Small,
    };
    private readonly List<string> _languageCodes = new();

    /// <summary>Builds (or rebuilds, after a language change) every text-bearing part of the window. The long-lived
    /// controls (game folder, activity log, option grid, update bar...) keep their state.</summary>
    private void BuildUi()
    {
        _buildingUi = true;
        SuspendLayout();
        HideInfo();
        foreach (var c in new Control[] { _gameDir, _autoWatch, _watchStatus, _log, _optionGrid, _basicButton, _advancedButton,
                                          _defaultsButton, _updateStatus, _languageBox, _updateBar })
            c.Parent?.Controls.Remove(c);
        foreach (var old in new[] { _content, _nav, _banner, _footer })
            if (old != null) { Controls.Remove(old); old.Dispose(); }

        Text = Lang.T("ui.window_title", AppInfo.VersionText, AppInfo.Credit);
        _autoWatch.Text = Lang.T("ui.auto_watch");
        _basicButton.Text = Lang.T("ui.basic");
        _advancedButton.Text = Lang.T("ui.advanced");
        _updateNotes.Text = Lang.T("ui.whats_new");
        _updateLater.Text = Lang.T("ui.later");

        // Pages
        var content = new Panel { Dock = DockStyle.Fill, BackColor = Theme.Bg };
        var play = BuildPlayPage();
        var featuresPage = new FeatureListView(FeatureCatalog.Load(Lang.Code)) { Dock = DockStyle.Fill, Visible = false };
        var settingsPage = BuildSettingsPage();
        settingsPage.Visible = false;
        content.Controls.Add(play);
        content.Controls.Add(featuresPage);
        content.Controls.Add(settingsPage);
        var aboutPage = BuildAboutPage();
        aboutPage.Visible = false;
        content.Controls.Add(aboutPage);

        // Navigation
        var nav = new Panel { Dock = DockStyle.Top, Height = Theme.S(46), BackColor = Theme.Bg, Padding = new Padding(Theme.S(16), 0, Theme.S(18), 0) };
        var pages = new (NavTab Tab, Control Page)[]
        {
            (new NavTab(Lang.T("ui.tab_play")), play),
            (new NavTab(Lang.T("ui.tab_features")), featuresPage),
            (new NavTab(Lang.T("ui.tab_settings")), settingsPage),
            (new NavTab(Lang.T("ui.tab_about")), aboutPage),
        };
        var tabs = new FlowLayoutPanel { Dock = DockStyle.Left, AutoSize = true, WrapContents = false, BackColor = Color.Transparent, Margin = Padding.Empty };
        void SelectPage(int index)
        {
            for (int i = 0; i < pages.Length; i++) { pages[i].Tab.Selected = i == index; pages[i].Page.Visible = i == index; }
            _page = index;
            if (pages[index].Page == settingsPage) { _config.Load(); RefreshOptionControls(); }
        }
        for (int i = 0; i < pages.Length; i++)
        {
            int index = i;
            tabs.Controls.Add(pages[i].Tab);
            pages[i].Tab.Click += (_, _) => SelectPage(index);
        }
        for (int i = 0; i < pages.Length; i++) { pages[i].Tab.Selected = i == _page; pages[i].Page.Visible = i == _page; }

        // Language picker: "Automatic (<Windows language>)" and every language with a file, each in its own name.
        _languageCodes.Clear();
        _languageBox.Items.Clear();
        var langs = Lang.Available();
        string winCode = Lang.Resolve("auto");
        string winName = langs.FirstOrDefault(l => l.Code == winCode).Name ?? "English";
        _languageCodes.Add("auto");
        _languageBox.Items.Add(Lang.T("lang.auto", winName));
        foreach (var (code, name) in langs) { _languageCodes.Add(code); _languageBox.Items.Add(name); }
        int sel = _languageCodes.IndexOf(_config.Values[ModConfig.LanguageKey]);
        _languageBox.SelectedIndex = sel >= 0 ? sel : 0;
        _tips.SetToolTip(_languageBox, Lang.T("ui.language_tip"));

        nav.Controls.Add(tabs);
        nav.Controls.Add(_updateStatus);
        nav.Paint += (_, e) => { using var p = new Pen(Theme.Border); e.Graphics.DrawLine(p, 0, nav.Height - 1, nav.Width, nav.Height - 1); };

        var banner = new BannerPanel { Dock = DockStyle.Top, VersionText = AppInfo.VersionText };
        _languageBox.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        banner.Controls.Add(_languageBox);

        // Footer
        var footer = new Panel { Dock = DockStyle.Bottom, Height = Theme.S(28), BackColor = Theme.Footer, Padding = new Padding(Theme.S(16), 0, Theme.S(16), 0) };
        var footerText = Theme.Label(Lang.T("ui.footer", AppInfo.VersionText, AppInfo.Credit), Theme.Small, Theme.Muted);
        footerText.AutoSize = false; footerText.Dock = DockStyle.Fill; footerText.TextAlign = ContentAlignment.MiddleLeft;
        var footerLink = new LinkLabel
        {
            Text = "GitHub", AutoSize = false, Dock = DockStyle.Right, Width = Theme.S(80), TextAlign = ContentAlignment.MiddleRight,
            Font = Theme.Small, LinkColor = Theme.Accent, ActiveLinkColor = Theme.AccentHover, LinkBehavior = LinkBehavior.HoverUnderline,
        };
        footerLink.LinkClicked += (_, _) => OpenUrl(AppInfo.RepoUrl);
        footer.Controls.Add(footerText);
        footer.Controls.Add(footerLink);

        // Docking order: the last added control docks first.
        Controls.Add(content);
        Controls.Add(footer);
        Controls.Add(nav);
        Controls.Add(_updateBar);
        Controls.Add(banner);
        (_content, _nav, _banner, _footer) = (content, nav, banner, footer);

        var oldMenu = _trayMenu;
        _trayMenu = new ContextMenuStrip();
        _trayMenu.Items.Add(Lang.T("ui.tray_open"), null, (_, _) => RestoreFromTray());
        _trayMenu.Items.Add(Lang.T("ui.tray_exit"), null, (_, _) => Close());
        _tray.ContextMenuStrip = _trayMenu;
        oldMenu?.Dispose();

        ShowUpdateState();
        UpdateWatchStatus();
        ResumeLayout(true);
        // Language picker at the top right of the banner, left of the version pill (see BannerPanel.OnPaint).
        int pillX = banner.ClientSize.Width - TextRenderer.MeasureText(AppInfo.VersionText, Theme.Bold, Size.Empty, TextFormatFlags.NoPadding).Width - Theme.S(44);
        _languageBox.Location = new Point(pillX - Theme.S(10) - _languageBox.Width, Theme.S(18));
        _buildingUi = false;
    }

    /// <summary>Picker changed: saves the language right away (also read by a running game) and rebuilds the window.
    /// Unsaved settings edits are kept.</summary>
    private void SwitchLanguage(string code)
    {
        ReadOptionControls();
        _config.Values[ModConfig.LanguageKey] = code;
        SaveSingleValue(ModConfig.LanguageKey, code);
        Lang.SetLanguage(Lang.Resolve(code));
        BuildUi();
        ActiveControl = _languageBox;
    }

    /// <summary>Writes one value to config.ini, leaving the other values on disk as they are.</summary>
    private void SaveSingleValue(string key, string value)
    {
        try
        {
            var disk = new ModConfig(_config.Path);
            disk.Load();
            disk.Values[key] = value;
            disk.Save();
            _lastConfigText = File.ReadAllText(_config.Path);
        }
        catch { /* not critical: saved with the other settings */ }
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Theme.DarkTitleBar(this);
    }

    private void Append(string s) => _log.AppendText(s + Environment.NewLine);

    private bool _trayHintShown;

    /// <summary>Shows the window again (from the tray, or when the launcher is started a second time).</summary>
    public void RestoreFromTray()
    {
        Show();
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        _tray.Visible = false;
        Activate();
        BringToFront();
    }

    // ---------------------------------------------------------------- Play page

    private Control BuildPlayPage()
    {
        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 4, BackColor = Theme.Bg,
            Padding = new Padding(Theme.S(20), Theme.S(14), Theme.S(20), Theme.S(10)),
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        for (int i = 0; i < 2; i++) layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        // Game folder card
        var folderCard = new Card { Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink };
        var folderGrid = new TableLayoutPanel { Dock = DockStyle.Top, ColumnCount = 2, RowCount = 2, AutoSize = true, BackColor = Color.Transparent };
        folderGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        folderGrid.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var folderCaption = Theme.CaptionLabel(Lang.T("ui.game_folder"));
        folderGrid.Controls.Add(folderCaption, 0, 0);
        folderGrid.SetColumnSpan(folderCaption, 2);
        _gameDir.Anchor = AnchorStyles.Left | AnchorStyles.Right;
        _gameDir.Dock = DockStyle.None;
        _gameDir.Margin = new Padding(0, Theme.S(4), Theme.S(8), 0);
        var browse = new ModernButton(Lang.T("ui.browse")) { Margin = new Padding(0) };
        browse.Click += (_, _) =>
        {
            using var dlg = new FolderBrowserDialog { Description = Lang.T("ui.browse_description") };
            if (dlg.ShowDialog(this) == DialogResult.OK) { _gameDir.Text = dlg.SelectedPath; SaveLauncherSettings(); }
        };
        folderGrid.Controls.Add(_gameDir, 0, 1);
        folderGrid.Controls.Add(browse, 1, 1);
        folderCard.Controls.Add(folderGrid);
        layout.Controls.Add(folderCard);

        // Ways to play: auto-load from VD / Meta Link (recommended, highlighted) and direct launch.
        var ways = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 2, RowCount = 1, BackColor = Color.Transparent, Margin = Padding.Empty };
        ways.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 63));
        ways.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 37));
        ways.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var vdCard = new Card { Dock = DockStyle.Fill, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Highlight = true, Margin = new Padding(0, 0, Theme.S(6), Theme.S(12)) };
        var vd = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 2, BackColor = Color.Transparent };
        vd.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        vd.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        void Span(Control c) { vd.Controls.Add(c); vd.SetColumnSpan(c, 2); }
        var rec = Theme.CaptionLabel(Lang.T("ui.recommended"));
        rec.ForeColor = Theme.Accent;
        rec.Margin = new Padding(0, 0, 0, Theme.S(2));
        Span(rec);
        var vdTitle = Theme.Label(Lang.T("ui.vd_title"), Theme.Big);
        vdTitle.Margin = new Padding(0, 0, 0, Theme.S(8));
        Span(vdTitle);
        string[] steps =
        {
            Lang.T("ui.vd_step1"),
            Lang.T("ui.vd_step2"),
            Lang.T("ui.vd_step3"),
        };
        for (int i = 0; i < steps.Length; i++)
        {
            var num = new StepBadge(i + 1) { Anchor = AnchorStyles.Top | AnchorStyles.Left, Margin = new Padding(0, Theme.S(2), Theme.S(10), Theme.S(4)) };
            var txt = Theme.Label(steps[i]);
            txt.Anchor = AnchorStyles.Left;
            txt.Margin = new Padding(0, Theme.S(3), 0, Theme.S(4));
            txt.MaximumSize = new Size(Theme.S(460), 0);
            vd.Controls.Add(num);
            vd.Controls.Add(txt);
        }
        _tips.SetToolTip(_autoWatch, Lang.T("ui.auto_watch_tip"));
        _autoWatch.Margin = new Padding(0, Theme.S(10), 0, 0);
        Span(_autoWatch);
        _watchStatus.Margin = new Padding(0, Theme.S(6), 0, 0);
        Span(_watchStatus);
        vdCard.Controls.Add(vd);
        ways.Controls.Add(vdCard, 0, 0);

        var launchCard = new Card { Dock = DockStyle.Fill, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Margin = new Padding(Theme.S(6), 0, 0, Theme.S(12)) };
        var lc = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3, BackColor = Color.Transparent };
        lc.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        lc.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        lc.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        lc.Controls.Add(Theme.CaptionLabel(Lang.T("ui.launch_caption")));
        var lcText = Theme.Label(Lang.T("ui.launch_text"), null, Theme.Muted);
        lcText.MaximumSize = new Size(Theme.S(260), 0);
        lc.Controls.Add(lcText);
        var launch = new ModernButton(Lang.T("ui.launch"), primary: true)
        {
            AutoSize = false, Dock = DockStyle.Fill, Height = Theme.S(50), Font = Theme.Big, Margin = new Padding(0, Theme.S(8), 0, 0),
        };
        launch.Click += async (_, _) =>
        {
            SaveLauncherSettings();
            if (!GameLocator.IsGameDir(_gameDir.Text)) { Append(Lang.T("ui.invalid_game_folder")); return; }
            launch.Enabled = false;
            try { await _svc.LaunchAsync(_gameDir.Text, _settings.ExtraArgs); }
            finally { launch.Enabled = true; }
        };
        lc.Controls.Add(launch);
        launchCard.Controls.Add(lc);
        launchCard.MinimumSize = new Size(0, Theme.S(150));
        ways.Controls.Add(launchCard, 1, 0);
        layout.Controls.Add(ways);

        // Activity log
        var logCard = new Card { Dock = DockStyle.Fill, Padding = new Padding(Theme.S(12), Theme.S(8), Theme.S(4), Theme.S(8)) };
        var logCaption = Theme.CaptionLabel(Lang.T("ui.activity"));
        logCaption.Dock = DockStyle.Top;
        logCard.Controls.Add(_log);
        logCard.Controls.Add(logCaption);
        layout.Controls.Add(logCard);

        // Bottom row
        var bottom = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 3, BackColor = Color.Transparent };
        bottom.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        bottom.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        bottom.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        var openLog = new ModernButton(Lang.T("ui.open_log")) { Margin = new Padding(0, 0, Theme.S(8), 0) };
        openLog.Click += (_, _) => OpenPath(Path.Combine(_baseDir, "ue4ss", "UE4SS.log"));
        var openMod = new ModernButton(Lang.T("ui.open_mod_folder")) { Margin = new Padding(0) };
        openMod.Click += (_, _) => OpenPath(Path.Combine(_baseDir, "ue4ss", "Mods", "MOHABPlus"));
        var help = Theme.Label(Lang.T("ui.ingame_help"), Theme.Small, Theme.Muted);
        help.Anchor = AnchorStyles.Right;
        help.Margin = new Padding(Theme.S(12), 0, 0, 0);
        bottom.Controls.Add(openLog, 0, 0);
        bottom.Controls.Add(openMod, 1, 0);
        bottom.Controls.Add(help, 2, 0);
        layout.Controls.Add(bottom);

        return layout;
    }

    private void UpdateWatchStatus()
    {
        bool on = _svc.IsWatching;
        _watchStatus.Text = Lang.T(on ? "ui.watch_on" : "ui.watch_off");
        _watchStatus.ForeColor = on ? Theme.Good : Theme.Accent;
    }

    // ---------------------------------------------------------------- About page

    private Control BuildAboutPage()
    {
        var outer = new Panel { Dock = DockStyle.Fill, BackColor = Theme.Bg, Padding = new Padding(Theme.S(20), Theme.S(14), Theme.S(20), Theme.S(14)) };
        var card = new Card { Dock = DockStyle.Fill, Padding = new Padding(Theme.S(22), Theme.S(18), Theme.S(22), Theme.S(16)) };
        var grid = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 5, BackColor = Color.Transparent };
        grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        grid.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var title = Theme.Label($"MOHAB Plus {AppInfo.VersionText}", Theme.Big);
        title.Margin = Padding.Empty;
        var by = Theme.Label(AppInfo.Credit, new Font("Segoe UI Semibold", 11f, FontStyle.Italic), Theme.Accent);
        by.Margin = new Padding(0, 0, 0, Theme.S(12));
        var caption = Theme.CaptionLabel(Lang.T("ui.disclaimer"));
        caption.ForeColor = Theme.Accent;
        var body = new Label
        {
            Dock = DockStyle.Fill, AutoSize = false, Font = Theme.Body, ForeColor = Theme.Text, BackColor = Color.Transparent,
            Text = Lang.Lines("ui.disclaimer_text"),
            Margin = new Padding(0, Theme.S(4), 0, Theme.S(8)),
        };
        var links = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, BackColor = Color.Transparent, Margin = Padding.Empty };
        var repo = new ModernButton(Lang.T("ui.project_github")) { Margin = new Padding(0, 0, Theme.S(8), 0) };
        repo.Click += (_, _) => OpenUrl(AppInfo.RepoUrl);
        var rel = new ModernButton(Lang.T("ui.releases")) { Margin = new Padding(0, 0, Theme.S(8), 0) };
        rel.Click += (_, _) => OpenUrl(AppInfo.ReleasesUrl);
        var ue = new ModernButton("UE4SS") { Margin = new Padding(0) };
        ue.Click += (_, _) => OpenUrl("https://github.com/UE4SS-RE/RE-UE4SS");
        links.Controls.Add(repo);
        links.Controls.Add(rel);
        links.Controls.Add(ue);

        grid.Controls.Add(title);
        grid.Controls.Add(by);
        grid.Controls.Add(caption);
        grid.Controls.Add(body);
        grid.Controls.Add(links);
        card.Controls.Add(grid);
        outer.Controls.Add(card);
        return outer;
    }

    // ---------------------------------------------------------------- Settings page

    private Control BuildSettingsPage()
    {
        var outer = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3, BackColor = Theme.Bg,
            Padding = new Padding(Theme.S(20), Theme.S(12), Theme.S(20), Theme.S(10)),
        };
        outer.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        outer.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        outer.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        // Intro + BASIC / ADVANCED selector (shared with the in-game menu through config.ini).
        var top = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 2, BackColor = Color.Transparent, Margin = new Padding(0, 0, 0, Theme.S(8)) };
        top.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        top.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var intro = Theme.Label(Lang.T("ui.settings_intro"), Theme.Small, Theme.Muted);
        intro.AutoSize = true;
        intro.MaximumSize = new Size(Theme.S(560), 0);
        intro.Anchor = AnchorStyles.Left;
        top.Controls.Add(intro);
        var views = new FlowLayoutPanel { AutoSize = true, WrapContents = false, BackColor = Color.Transparent, Margin = Padding.Empty, Anchor = AnchorStyles.Right };
        _basicButton.Margin = new Padding(0, 0, Theme.S(4), 0);
        _advancedButton.Margin = Padding.Empty;
        views.Controls.Add(_basicButton);
        views.Controls.Add(_advancedButton);
        top.Controls.Add(views);
        outer.Controls.Add(top);

        var card = new Card { Dock = DockStyle.Fill, Padding = new Padding(Theme.S(4)) };
        _optionGrid.Dock = DockStyle.Fill;
        _descriptions = ModConfig.LoadDescriptions(_config.Path, Lang.Code);
        PopulateOptionGrid();
        card.Controls.Add(_optionGrid);
        outer.Controls.Add(card);

        var buttons = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, FlowDirection = FlowDirection.RightToLeft, BackColor = Color.Transparent, Margin = Padding.Empty };
        var save = new ModernButton(Lang.T("ui.save"), primary: true) { Margin = new Padding(Theme.S(8), 0, 0, 0) };
        save.Click += (_, _) => { ReadOptionControls(); _config.Save(); Append(Lang.T("ui.saved")); };
        var reload = new ModernButton(Lang.T("ui.reload")) { Margin = new Padding(Theme.S(8), 0, 0, 0) };
        reload.Click += (_, _) => { _config.Load(); ShowConfig(); };
        _defaultsButton.Margin = new Padding(Theme.S(8), 0, 0, 0);
        buttons.Controls.Add(save);
        buttons.Controls.Add(reload);
        buttons.Controls.Add(_defaultsButton);
        outer.Controls.Add(buttons);

        outer.VisibleChanged += (_, _) => { if (!outer.Visible) HideInfo(); };
        return outer;
    }

    private readonly TableLayoutPanel _optionGrid = new();
    private readonly ModernButton _basicButton = new(Lang.T("ui.basic"));
    private readonly ModernButton _advancedButton = new(Lang.T("ui.advanced"));
    private readonly ModernButton _defaultsButton = new(Lang.T("ui.defaults"));
    private readonly InfoPopup _infoPopup = new();
    private Dictionary<string, List<string>> _descriptions = new();
    private InfoIcon? _pinnedInfo;
    private string? _shownView;

    private bool AdvancedView => _config.Values[ModConfig.ViewKey] == "advanced";

    /// <summary>Rebuilds the option rows for the current view (basic: a few main options, advanced: all of them).</summary>
    private void PopulateOptionGrid()
    {
        HideInfo();
        bool advanced = AdvancedView;
        _shownView = _config.Values[ModConfig.ViewKey];
        _basicButton.Primary = !advanced;
        _advancedButton.Primary = advanced;
        _basicButton.Invalidate();
        _advancedButton.Invalidate();
        _defaultsButton.Text = Lang.T(advanced ? "ui.defaults" : "ui.defaults_all");

        var groups = advanced
            ? ModConfig.Options.Where(o => !ModConfig.HasOwnControl(o.Key)).GroupBy(o => o.Section).Select(g => (g.Key, g.ToArray()))
            : ModConfig.BasicLayout.Select(b => (b.Section, b.Keys.Select(k => ModConfig.Options.First(o => o.Key == k)).ToArray()));

        var grid = _optionGrid;
        grid.SuspendLayout();
        foreach (Control old in grid.Controls.Cast<Control>().ToArray()) old.Dispose();
        grid.Controls.Clear();
        grid.RowStyles.Clear();
        grid.RowCount = 0;
        _optionControls.Clear();
        foreach (var (section, options) in groups)
        {
            var header = new Label
            {
                Text = Lang.Section(section).ToUpper(), AutoSize = true, Font = Theme.Caption, ForeColor = Theme.Accent,
                Margin = new Padding(0, Theme.S(14), 0, Theme.S(4)),
            };
            grid.Controls.Add(header);
            grid.SetColumnSpan(header, 2);
            foreach (var o in options)
            {
                var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false, BackColor = Color.Transparent, Anchor = AnchorStyles.Left, Margin = new Padding(0, Theme.S(2), Theme.S(8), Theme.S(2)) };
                var label = Theme.Label(o.Label);
                label.Margin = new Padding(0, Theme.S(3), Theme.S(4), Theme.S(3));
                row.Controls.Add(label);
                var info = new InfoIcon { Margin = new Padding(0, Theme.S(5), 0, 0) };
                var opt = o;
                info.MouseEnter += (_, _) => { if (_pinnedInfo == null) ShowInfo(info, opt); };
                info.MouseLeave += (_, _) => { if (_pinnedInfo == null) _infoPopup.Hide(); };
                info.MouseDown += (_, e) =>
                {
                    if (e.Button != MouseButtons.Left) return;
                    if (_pinnedInfo == info) { HideInfo(); return; }
                    if (_pinnedInfo != null) _pinnedInfo.Pinned = false;
                    _pinnedInfo = info;
                    info.Pinned = true;
                    ShowInfo(info, opt);
                };
                row.Controls.Add(info);
                grid.Controls.Add(row);

                Control c = o.Kind switch
                {
                    OptionKind.Bool => new ModernCheck(),
                    OptionKind.Float => new NumericUpDown
                    {
                        DecimalPlaces = 2, Minimum = (decimal)o.Min, Maximum = (decimal)o.Max,
                        Increment = (decimal)o.Step, Width = Theme.S(100),
                        BackColor = Theme.Surface2, ForeColor = Theme.Text, BorderStyle = BorderStyle.FixedSingle,
                    },
                    _ => new ComboBox
                    {
                        DropDownStyle = ComboBoxStyle.DropDownList, Width = Theme.S(140), FlatStyle = FlatStyle.Flat,
                        BackColor = Theme.Surface2, ForeColor = Theme.Text,
                    },
                };
                if (c is ComboBox cb && o.Choices != null) cb.Items.AddRange(o.Choices.Select(o.ChoiceLabel).ToArray());
                c.Anchor = AnchorStyles.Left;
                c.Margin = new Padding(0, Theme.S(3), 0, Theme.S(3));
                _optionControls[o.Key] = c;
                grid.Controls.Add(c);
            }
        }
        if (!advanced)
        {
            var more = Theme.Label(Lang.T("ui.more_in_advanced"), Theme.Small, Theme.Muted);
            more.AutoSize = true;
            more.MaximumSize = new Size(Theme.S(520), 0);
            more.Margin = new Padding(0, Theme.S(16), 0, 0);
            grid.Controls.Add(more);
            grid.SetColumnSpan(more, 2);
        }
        RefreshOptionControls();
        grid.ResumeLayout();
        grid.AutoScrollPosition = Point.Empty;
    }

    /// <summary>Switches view, keeping unsaved edits; only the view is written to config.ini right away.</summary>
    private void SwitchView(string view)
    {
        if (_config.Values[ModConfig.ViewKey] == view) return;
        ReadOptionControls();
        _config.Values[ModConfig.ViewKey] = view;
        SaveSingleValue(ModConfig.ViewKey, view);
        PopulateOptionGrid();
    }

    private void ShowInfo(InfoIcon icon, ModOption o)
    {
        var paragraphs = _descriptions.TryGetValue(o.Key, out var p) ? p : new List<string> { Lang.T("ui.no_description") };
        _infoPopup.ShowFor(icon, o.Label, paragraphs, Lang.T("ui.default_value", ModConfig.DisplayValue(o, o.Default)));
    }

    private void HideInfo()
    {
        if (_pinnedInfo != null && !_pinnedInfo.IsDisposed) _pinnedInfo.Pinned = false;
        _pinnedInfo = null;
        if (_infoPopup.Visible) _infoPopup.Hide();
    }

    /// <summary>A click anywhere but on an info icon closes a pinned description.</summary>
    private sealed class ClickOutsideFilter : IMessageFilter
    {
        private readonly MainForm _form;
        public ClickOutsideFilter(MainForm form) { _form = form; }
        public bool PreFilterMessage(ref Message m)
        {
            const int WM_LBUTTONDOWN = 0x201, WM_RBUTTONDOWN = 0x204, WM_NCLBUTTONDOWN = 0xA1;
            if (m.Msg is WM_LBUTTONDOWN or WM_RBUTTONDOWN or WM_NCLBUTTONDOWN && _form._pinnedInfo != null)
            {
                if (Control.FromHandle(m.HWnd) is not InfoIcon) _form.HideInfo();
            }
            return false;
        }
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
        ShowConfig();
    }

    /// <summary>Shows the loaded values, switching view if the in-game menu changed it.</summary>
    private void ShowConfig()
    {
        if (Lang.Resolve(_config.Values[ModConfig.LanguageKey]) != Lang.Code)
        {
            Lang.SetLanguage(Lang.Resolve(_config.Values[ModConfig.LanguageKey]));
            BuildUi();
            return;
        }
        if (_config.Values[ModConfig.ViewKey] != _shownView) PopulateOptionGrid();
        else RefreshOptionControls();
    }

    private void RefreshOptionControls()
    {
        foreach (var (key, c) in _optionControls)
        {
            var o = ModConfig.Options.First(x => x.Key == key);
            switch (c)
            {
                case CheckBox cb: cb.Checked = _config.GetBool(o.Key); break;
                case NumericUpDown n:
                    n.Value = Math.Clamp((decimal)_config.GetFloat(o.Key), n.Minimum, n.Maximum); break;
                case ComboBox combo:
                    combo.SelectedIndex = Array.IndexOf(o.Choices!, _config.Values[o.Key]);
                    if (combo.SelectedIndex < 0) combo.SelectedIndex = Array.IndexOf(o.Choices!, o.Default);
                    break;
            }
        }
    }

    /// <summary>Copies the shown controls into the config values (options hidden by the basic view keep theirs).</summary>
    private void ReadOptionControls()
    {
        foreach (var (key, c) in _optionControls)
        {
            var o = ModConfig.Options.First(x => x.Key == key);
            switch (c)
            {
                case CheckBox cb: _config.Set(o.Key, cb.Checked); break;
                case NumericUpDown n: _config.Set(o.Key, (double)n.Value); break;
                case ComboBox combo: _config.Set(o.Key, combo.SelectedIndex >= 0 ? o.Choices![combo.SelectedIndex] : o.Default); break;
            }
        }
    }

    // ---------------------------------------------------------------- Updates

    private void BuildUpdateBar()
    {
        _updateBar.Height = Theme.S(52);
        _updateBar.Padding = new Padding(Theme.S(20), Theme.S(8), Theme.S(12), Theme.S(8));
        _updateBar.Paint += (_, e) =>
        {
            using var b = new SolidBrush(Theme.Accent);
            e.Graphics.FillRectangle(b, 0, 0, Theme.S(4), _updateBar.Height);
        };
        _updateText.AutoSize = false;
        _updateText.Dock = DockStyle.Fill;
        _updateText.TextAlign = ContentAlignment.MiddleLeft;
        _updateText.ForeColor = Theme.Text;

        var buttons = new FlowLayoutPanel { Dock = DockStyle.Right, AutoSize = true, WrapContents = false, BackColor = Color.Transparent, Margin = Padding.Empty };
        _updateLater.Margin = new Padding(Theme.S(6), 0, 0, 0);
        _updateNotes.Margin = new Padding(Theme.S(6), 0, 0, 0);
        _updateNow.Margin = new Padding(Theme.S(6), 0, 0, 0);
        _updateLater.Click += (_, _) => _updateBar.Visible = false;
        _updateNotes.Click += (_, _) => { if (_available != null) ShowReleaseNotes(_available); };
        _updateNow.Click += async (_, _) => { if (_available != null) await InstallUpdateAsync(_available); };
        buttons.Controls.Add(_updateNotes);
        buttons.Controls.Add(_updateNow);
        buttons.Controls.Add(_updateLater);

        _updateBar.Controls.Add(_updateText);
        _updateBar.Controls.Add(buttons);
    }

    private void SetUpdateStatus(string text, Color color)
    {
        _updateStatus.Text = text;
        _updateStatus.LinkColor = color;
        _updateStatus.VisitedLinkColor = color;
    }

    private async Task CheckForUpdatesAsync(bool manual)
    {
        if (_checking || _installing) return;
        _checking = true;
        SetUpdateStatus(Lang.T("ui.checking"), Theme.Muted);
        try
        {
            var r = await Updater.CheckAsync();
#if DEBUG
            // UI test hook: MOHABPLUS_FAKE_UPDATE=0.9.0 pretends that release exists.
            if (AppInfo.ParseTag(Environment.GetEnvironmentVariable("MOHABPLUS_FAKE_UPDATE")) is { } fake)
                r = new(UpdateCheckState.UpdateAvailable, new ReleaseInfo(fake, "v" + fake, "MOHAB Plus v" + fake,
                    "## New\n- Fake release used to test the update UI.\n\n## Fixes\n- Nothing real.", AppInfo.ReleasesUrl, null, 0));
#endif
            _lastCheck = r;
            _available = r.State == UpdateCheckState.UpdateAvailable ? r.Release : null;
            _checking = false;
            ShowUpdateState();
            switch (r.State)
            {
                case UpdateCheckState.UpdateAvailable:
                    _updateBar.Visible = true;
                    Append(Lang.T("ui.update_available_log", AppInfo.Format(_available!.Version), _updateNow.Text));
                    break;
                case UpdateCheckState.UpToDate:
                    if (manual) Append(Lang.T("ui.up_to_date", AppInfo.VersionText));
                    break;
                case UpdateCheckState.NoReleases:
                    if (manual) Append(Lang.T("ui.no_releases"));
                    break;
                default:
                    if (manual) Append(Lang.T("ui.check_failed", r.Error));
                    break;
            }
        }
        finally { _checking = false; }
    }

    private UpdateCheckResult? _lastCheck;

    /// <summary>Shows the last update check (top bar status, update bar texts) in the current language.</summary>
    private void ShowUpdateState()
    {
        _updateNow.Text = Lang.T("ui.update_now");
        if (_checking) { SetUpdateStatus(Lang.T("ui.checking"), Theme.Muted); return; }
        if (_lastCheck == null) { SetUpdateStatus("", Theme.Muted); return; }
        switch (_lastCheck.State)
        {
            case UpdateCheckState.UpdateAvailable when _available != null:
                string v = AppInfo.Format(_available.Version);
                SetUpdateStatus(Lang.T("ui.update_available_short", v), Theme.Accent);
                if (!_installing) _updateText.Text = Lang.T("ui.update_available", v, AppInfo.VersionText);
                _updateNow.Text = _available.ZipUrl != null ? Lang.T("ui.update_to", v) : Lang.T("ui.download_page");
                break;
            case UpdateCheckState.UpToDate:
                SetUpdateStatus(Lang.T("ui.up_to_date_short", AppInfo.VersionText), Theme.Muted);
                break;
            case UpdateCheckState.NoReleases:
                SetUpdateStatus(Lang.T("ui.no_releases_short"), Theme.Muted);
                break;
            default:
                SetUpdateStatus(Lang.T("ui.check_failed_short"), Theme.Muted);
                break;
        }
    }

    private void ShowReleaseNotes(ReleaseInfo rel)
    {
        using var dlg = new ReleaseNotesForm(rel);
        var result = dlg.ShowDialog(this);
        if (result == DialogResult.Yes) _ = InstallUpdateAsync(rel);
    }

    private async Task InstallUpdateAsync(ReleaseInfo rel)
    {
        if (_installing) return;
        string v = AppInfo.Format(rel.Version);
        if (rel.ZipUrl == null) { OpenUrl(rel.PageUrl.Length > 0 ? rel.PageUrl : AppInfo.ReleasesUrl); return; }
        if (ModInjectorService.FindGameProcesses().Length > 0)
        {
            MessageBox.Show(this, Lang.T("ui.update_close_game"), Lang.T("ui.update_title"), MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        if (MessageBox.Show(this,
                Lang.Lines("ui.update_confirm", AppInfo.VersionText, v),
                Lang.T("ui.update_title"), MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes)
            return;

        _installing = true;
        _updateNow.Enabled = _updateNotes.Enabled = false;
        bool wasWatching = _svc.IsWatching;
        _svc.StopWatching();
        var progress = new Progress<string>(s => { _updateText.Text = "⬆   " + s; });
        try
        {
            Append(Lang.T("ui.updating", v));
            await Updater.InstallAsync(rel, _baseDir, progress);
            Append(Lang.T("ui.update_installed"));
            Updater.Restart(_baseDir, rel.Version);
            Close();
        }
        catch (Exception ex)
        {
            Append(Lang.T("ui.update_failed_log", ex.Message));
            _updateText.Text = Lang.T("ui.update_failed_bar", v, ex.Message);
            MessageBox.Show(this, Lang.Lines("ui.update_failed", ex.Message),
                Lang.T("ui.update_title"), MessageBoxButtons.OK, MessageBoxIcon.Warning);
            if (wasWatching) _svc.StartWatching();
            UpdateWatchStatus();
        }
        finally
        {
            _installing = false;
            _updateNow.Enabled = _updateNotes.Enabled = true;
        }
    }

    // ---------------------------------------------------------------- Helpers

    private void SaveLauncherSettings()
    {
        _settings.GameDir = _gameDir.Text.Trim();
        _settings.AutoWatch = _autoWatch.Checked;
        try { _settings.Save(); } catch (Exception ex) { Append(Lang.T("ui.launcher_ini_error", ex.Message)); }
    }

    private void OpenPath(string path)
    {
        if (!File.Exists(path) && !Directory.Exists(path)) { Append(Lang.T("ui.not_found", path)); return; }
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    }

    internal static void OpenUrl(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { /* no browser */ }
    }
}

/// <summary>Shows the notes of a GitHub release. DialogResult.Yes = install it.</summary>
internal sealed class ReleaseNotesForm : Form
{
    public ReleaseNotesForm(ReleaseInfo rel)
    {
        string v = AppInfo.Format(rel.Version);
        Text = Lang.T("ui.notes_title", v);
        AutoScaleMode = AutoScaleMode.None;
        ClientSize = new Size(Theme.S(620), Theme.S(460));
        MinimumSize = new Size(Theme.S(420), Theme.S(300));
        StartPosition = FormStartPosition.CenterParent;
        BackColor = Theme.Bg; ForeColor = Theme.Text; Font = Theme.Body;
        Icon = Theme.LoadIcon();
        ShowInTaskbar = false;
        MinimizeBox = false;

        var title = Theme.Label(string.IsNullOrWhiteSpace(rel.Name) ? $"MOHAB Plus {v}" : rel.Name, Theme.Big);
        title.Dock = DockStyle.Top;
        title.Padding = new Padding(Theme.S(16), Theme.S(14), Theme.S(16), Theme.S(8));

        var notes = new TextBox
        {
            Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, BorderStyle = BorderStyle.None,
            BackColor = Theme.Surface, ForeColor = Theme.Text, Font = Theme.Body,
            Text = (string.IsNullOrWhiteSpace(rel.Notes) ? Lang.T("ui.no_notes") : rel.Notes).Replace("\r\n", "\n").Replace("\n", Environment.NewLine),
        };
        Theme.DarkScrollBars(notes);
        var card = new Card { Dock = DockStyle.Fill, Padding = new Padding(Theme.S(12)) };
        card.Controls.Add(notes);
        var body = new Panel { Dock = DockStyle.Fill, Padding = new Padding(Theme.S(16), 0, Theme.S(16), 0), BackColor = Theme.Bg };
        body.Controls.Add(card);

        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom, AutoSize = true, FlowDirection = FlowDirection.RightToLeft, BackColor = Theme.Bg,
            Padding = new Padding(Theme.S(12), 0, Theme.S(12), Theme.S(10)),
        };
        var install = new ModernButton(rel.ZipUrl != null ? Lang.T("ui.update_to", v) : Lang.T("ui.download_page"), primary: true);
        install.Click += (_, _) => { DialogResult = DialogResult.Yes; Close(); };
        var page = new ModernButton(Lang.T("ui.open_github"));
        page.Click += (_, _) => MainForm.OpenUrl(rel.PageUrl.Length > 0 ? rel.PageUrl : AppInfo.ReleasesUrl);
        var close = new ModernButton(Lang.T("ui.close"));
        close.Click += (_, _) => { DialogResult = DialogResult.Cancel; Close(); };
        buttons.Controls.Add(install);
        buttons.Controls.Add(page);
        buttons.Controls.Add(close);

        Controls.Add(body);
        Controls.Add(buttons);
        Controls.Add(title);
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Theme.DarkTitleBar(this);
    }
}
