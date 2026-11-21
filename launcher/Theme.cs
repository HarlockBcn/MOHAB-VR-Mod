using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace MOHABPlus;

/// <summary>Dark colour palette (warm gold accent taken from the game's key art) and small styling helpers.</summary>
internal static class Theme
{
    public static readonly Color Bg = Color.FromArgb(18, 20, 23);
    public static readonly Color Footer = Color.FromArgb(13, 15, 18);
    public static readonly Color Surface = Color.FromArgb(28, 31, 36);
    public static readonly Color Surface2 = Color.FromArgb(38, 42, 49);
    public static readonly Color SurfaceHover = Color.FromArgb(50, 56, 65);
    public static readonly Color Border = Color.FromArgb(52, 58, 66);
    public static readonly Color Text = Color.FromArgb(234, 230, 222);
    public static readonly Color Muted = Color.FromArgb(150, 156, 165);
    public static readonly Color Accent = Color.FromArgb(226, 165, 62);
    public static readonly Color AccentHover = Color.FromArgb(242, 184, 86);
    public static readonly Color AccentDown = Color.FromArgb(196, 140, 46);
    public static readonly Color AccentText = Color.FromArgb(28, 20, 8);
    public static readonly Color Good = Color.FromArgb(111, 207, 127);
    public static readonly Color Bad = Color.FromArgb(232, 112, 96);
    public static readonly Color UpdateBg = Color.FromArgb(58, 44, 18);

    public static float Dpi = 1f;
    public static int S(float v) => (int)Math.Round(v * Dpi);

    public static readonly Font Body = new("Segoe UI", 9.75f);
    public static readonly Font Small = new("Segoe UI", 8.5f);
    public static readonly Font Bold = new("Segoe UI Semibold", 9.75f);
    public static readonly Font Caption = new("Segoe UI Semibold", 8.25f);
    public static readonly Font Big = new("Segoe UI Semibold", 12.5f);
    public static readonly Font Mono = new("Consolas", 9f);

    public static GraphicsPath Round(RectangleF r, float radius)
    {
        var p = new GraphicsPath();
        float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        if (d <= 0) { p.AddRectangle(r); return p; }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    public static Label Label(string text, Font? font = null, Color? color = null) => new()
    {
        Text = text, AutoSize = true, Font = font ?? Body, ForeColor = color ?? Text, BackColor = Color.Transparent,
    };

    /// <summary>Small upper-case section caption.</summary>
    public static Label CaptionLabel(string text) => new()
    {
        Text = text.ToUpperInvariant(), AutoSize = true, Font = Caption, ForeColor = Muted, BackColor = Color.Transparent,
        Margin = new Padding(0, S(4), 0, S(4)),
    };

    public static void Style(CheckBox cb)
    {
        cb.FlatStyle = FlatStyle.Flat;
        cb.FlatAppearance.BorderColor = Muted;
        cb.FlatAppearance.CheckedBackColor = Accent;
        cb.FlatAppearance.MouseOverBackColor = SurfaceHover;
        cb.ForeColor = Text;
        cb.BackColor = Color.Transparent;
        cb.Font = Body;
        cb.Cursor = Cursors.Hand;
    }

    public static void Style(TextBox tb, Color? back = null)
    {
        tb.BackColor = back ?? Surface2;
        tb.ForeColor = Text;
        tb.BorderStyle = BorderStyle.FixedSingle;
        tb.Font = Body;
    }

    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] private static extern int SetWindowTheme(IntPtr hwnd, string? app, string? idList);

    /// <summary>Dark title bar (Windows 10 2004+ / 11; ignored elsewhere).</summary>
    public static void DarkTitleBar(Form f)
    {
        try { int on = 1; if (DwmSetWindowAttribute(f.Handle, 20, ref on, 4) != 0) DwmSetWindowAttribute(f.Handle, 19, ref on, 4); }
        catch { /* older Windows */ }
    }

    /// <summary>Dark scroll bars on a scrollable control (applied once its handle exists).</summary>
    public static void DarkScrollBars(Control c)
    {
        void Apply() { try { SetWindowTheme(c.Handle, "DarkMode_Explorer", null); } catch { } }
        if (c.IsHandleCreated) Apply(); else c.HandleCreated += (_, _) => Apply();
    }

    public static Image? LoadImage(string name)
    {
        var s = typeof(Theme).Assembly.GetManifestResourceStream("MOHABPlus." + name);
        return s == null ? null : Image.FromStream(s);
    }

    public static Icon LoadIcon()
    {
        var s = typeof(Theme).Assembly.GetManifestResourceStream("MOHABPlus.app.ico");
        return s == null ? SystemIcons.Application : new Icon(s);
    }
}

/// <summary>Flat rounded button: gold "primary" or dark "secondary".</summary>
internal sealed class ModernButton : Button
{
    private bool _hover, _down;
    public bool Primary { get; set; }

    public ModernButton(string text, bool primary = false)
    {
        Text = text;
        Primary = primary;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        Font = primary ? Theme.Bold : Theme.Body;
        Cursor = Cursors.Hand;
        AutoSize = true;
        BackColor = Color.Transparent;
        Padding = new Padding(Theme.S(14), Theme.S(6), Theme.S(14), Theme.S(6));
        Margin = new Padding(Theme.S(4));
    }

    public override Size GetPreferredSize(Size proposed)
    {
        var t = TextRenderer.MeasureText(Text, Font);
        return new Size(t.Width + Padding.Horizontal, t.Height + Padding.Vertical);
    }

    protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hover = false; _down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { _down = true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { _down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(EffectiveBack(Parent));
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Color fill, fore, border;
        if (!Enabled) { fill = Theme.Surface2; fore = Theme.Muted; border = Theme.Border; }
        else if (Primary) { fill = _down ? Theme.AccentDown : _hover ? Theme.AccentHover : Theme.Accent; fore = Theme.AccentText; border = fill; }
        else { fill = _down ? Theme.Border : _hover ? Theme.SurfaceHover : Theme.Surface2; fore = Theme.Text; border = _hover ? Theme.Muted : Theme.Border; }
        var r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        using (var path = Theme.Round(r, Theme.S(6)))
        {
            using var b = new SolidBrush(fill);
            g.FillPath(b, path);
            using var p = new Pen(border);
            g.DrawPath(p, path);
        }
        TextRenderer.DrawText(g, Text, Font, ClientRectangle, fore,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        if (Focused && ShowFocusCues)
        {
            using var p = new Pen(Primary ? Theme.AccentText : Theme.Accent) { DashStyle = DashStyle.Dot };
            g.DrawRectangle(p, Theme.S(4), Theme.S(4), Width - Theme.S(8) - 1, Height - Theme.S(8) - 1);
        }
    }

    internal static Color EffectiveBack(Control? c)
    {
        while (c != null && c.BackColor.A < 255) c = c.Parent;
        return c?.BackColor ?? Theme.Bg;
    }
}

/// <summary>Rounded "card" container.</summary>
internal sealed class Card : Panel
{
    /// <summary>Gold border and a slightly warmer background, for the recommended option.</summary>
    public bool Highlight { get; set; }

    public Card()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
        BackColor = Theme.Surface;
        Padding = new Padding(Theme.S(14));
        Margin = new Padding(0, 0, 0, Theme.S(12));
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(ModernButton.EffectiveBack(Parent));
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = Theme.Round(new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), Theme.S(8));
        using var b = new SolidBrush(BackColor);
        g.FillPath(b, path);
        using var p = new Pen(Highlight ? Theme.Accent : Theme.Border, Highlight ? Math.Max(1.5f, Theme.S(1.5f)) : 1f);
        g.DrawPath(p, path);
    }

    protected override void OnCreateControl()
    {
        base.OnCreateControl();
        if (Highlight && BackColor == Theme.Surface) BackColor = Color.FromArgb(34, 31, 26);
    }
}

/// <summary>Top navigation tab with an accent underline when selected.</summary>
internal sealed class NavTab : Control
{
    private bool _selected, _hover;
    public bool Selected { get => _selected; set { _selected = value; Invalidate(); } }

    public NavTab(string text)
    {
        Text = text;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Font = Theme.Bold;
        Cursor = Cursors.Hand;
        var t = TextRenderer.MeasureText(text, Font);
        Size = new Size(t.Width + Theme.S(28), Theme.S(44));
        Margin = Padding.Empty;
    }

    protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hover = false; Invalidate(); base.OnMouseLeave(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(ModernButton.EffectiveBack(Parent));
        var color = _selected ? Theme.Text : _hover ? Theme.Text : Theme.Muted;
        TextRenderer.DrawText(g, Text, Font, ClientRectangle, color, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        if (_selected)
        {
            using var b = new SolidBrush(Theme.Accent);
            g.FillRectangle(b, Theme.S(10), Height - Theme.S(3), Width - Theme.S(20), Theme.S(3));
        }
    }
}

/// <summary>Header with the game's key art, the game logo, the "PLUS" mark and the mod version.</summary>
internal sealed class BannerPanel : Control
{
    private readonly Image? _art = Theme.LoadImage("banner.jpg");
    private readonly Image? _logo = Theme.LoadImage("logo.png");
    public string VersionText { get; set; } = "";

    public BannerPanel()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Height = Theme.S(210);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(Theme.Bg);
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        int w = Width, h = Height;
        if (w <= 0 || h <= 0) return;

        // Key art, "cover" scaled, the soldier kept at ~64% of the width so the logo has room on the left.
        if (_art != null)
        {
            float scale = Math.Max((float)w / _art.Width, (float)h / _art.Height);
            float sw = w / scale, sh = h / scale;
            float sx = Math.Clamp(_art.Width * 0.51f - sw * 0.64f, 0, _art.Width - sw);
            float sy = Math.Clamp(_art.Height * 0.28f - sh * 0.28f, 0, _art.Height - sh);
            g.DrawImage(_art, new RectangleF(0, 0, w, h), new RectangleF(sx, sy, sw, sh), GraphicsUnit.Pixel);
        }

        // Darken the left side for the logo and fade the bottom into the window background.
        using (var left = new LinearGradientBrush(new Rectangle(0, 0, w, h), Color.FromArgb(225, Theme.Bg), Color.FromArgb(0, Theme.Bg), 0f))
        {
            var blend = new ColorBlend
            {
                Positions = new[] { 0f, 0.38f, 0.62f, 1f },
                Colors = new[] { Color.FromArgb(225, Theme.Bg), Color.FromArgb(170, Theme.Bg), Color.FromArgb(0, Theme.Bg), Color.FromArgb(0, Theme.Bg) },
            };
            left.InterpolationColors = blend;
            g.FillRectangle(left, 0, 0, w, h);
        }
        int fadeTop = (int)(h * 0.55f);
        using (var bottom = new LinearGradientBrush(new Rectangle(0, fadeTop - 1, w, h - fadeTop + 1), Color.FromArgb(0, Theme.Bg), Theme.Bg, 90f))
            g.FillRectangle(bottom, 0, fadeTop, w, h - fadeTop);

        // Game logo + PLUS mark
        int x = Theme.S(30), y = Theme.S(34);
        int logoW = Theme.S(300);
        if (_logo != null)
        {
            int logoH = logoW * _logo.Height / _logo.Width;
            g.DrawImage(_logo, new Rectangle(x, y, logoW, logoH));
            y += logoH + Theme.S(10);
        }
        using (var plusFont = new Font("Segoe UI Black", 24f, FontStyle.Bold))
        {
            int px = x;
            foreach (char ch in "PLUS")
            {
                string s = ch.ToString();
                TextRenderer.DrawText(g, s, plusFont, new Point(px, y), Theme.Accent, TextFormatFlags.NoPadding);
                px += TextRenderer.MeasureText(g, s, plusFont, Size.Empty, TextFormatFlags.NoPadding).Width + Theme.S(7);
            }
            int lineY = y + TextRenderer.MeasureText(g, "P", plusFont, Size.Empty, TextFormatFlags.NoPadding).Height / 2;
            // Author credit at the end of the line: "PLUS ——— by Harlock"
            using var byFont = new Font("Segoe UI Semibold", 12f, FontStyle.Italic);
            var bySize = TextRenderer.MeasureText(g, AppInfo.Credit, byFont, Size.Empty, TextFormatFlags.NoPadding);
            int byX = Math.Max(x + logoW - bySize.Width, px + Theme.S(40));
            TextRenderer.DrawText(g, AppInfo.Credit, byFont, new Point(byX, lineY - bySize.Height / 2 - Theme.S(1)), Theme.Text, TextFormatFlags.NoPadding);
            using var pen = new Pen(Color.FromArgb(150, Theme.Accent), Theme.S(2));
            if (byX - Theme.S(10) > px + Theme.S(8)) g.DrawLine(pen, px + Theme.S(6), lineY, byX - Theme.S(10), lineY);
            y += TextRenderer.MeasureText(g, "P", plusFont, Size.Empty, TextFormatFlags.NoPadding).Height + Theme.S(6);
        }
        TextRenderer.DrawText(g, "VR gameplay enhancements  ·  no game files modified", Theme.Body, new Point(x, y), Color.FromArgb(215, Theme.Text), TextFormatFlags.NoPadding);

        // Version pill (top right)
        if (VersionText.Length > 0)
        {
            var size = TextRenderer.MeasureText(g, VersionText, Theme.Bold, Size.Empty, TextFormatFlags.NoPadding);
            var pill = new Rectangle(w - size.Width - Theme.S(44), Theme.S(16), size.Width + Theme.S(24), size.Height + Theme.S(10));
            using var path = Theme.Round(pill, pill.Height / 2f);
            using var fill = new SolidBrush(Color.FromArgb(200, Theme.Bg));
            g.FillPath(fill, path);
            using var pen = new Pen(Theme.Accent, Math.Max(1, Theme.S(1.5f)));
            g.DrawPath(pen, path);
            TextRenderer.DrawText(g, VersionText, Theme.Bold, pill, Theme.Accent, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { _art?.Dispose(); _logo?.Dispose(); }
        base.Dispose(disposing);
    }
}

/// <summary>Check box with a rounded gold box (the flat WinForms one draws an invisible tick on dark themes).</summary>
internal sealed class ModernCheck : CheckBox
{
    private bool _hover;

    public ModernCheck()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        AutoSize = true;
        Font = Theme.Body;
        ForeColor = Theme.Text;
        BackColor = Color.Transparent;
        Cursor = Cursors.Hand;
    }

    private int Box => Theme.S(16);
    private int Gap => Text.Length > 0 ? Theme.S(8) : 0;

    public override Size GetPreferredSize(Size proposed)
    {
        var t = Text.Length > 0 ? TextRenderer.MeasureText(Text, Font) : Size.Empty;
        return new Size(Box + Gap + t.Width + Theme.S(2), Math.Max(Box + Theme.S(4), t.Height + Theme.S(2)));
    }

    protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hover = false; Invalidate(); base.OnMouseLeave(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(ModernButton.EffectiveBack(Parent));
        g.SmoothingMode = SmoothingMode.AntiAlias;
        int y = (Height - Box) / 2;
        var r = new RectangleF(1, y + 0.5f, Box - 1, Box - 1);
        using (var path = Theme.Round(r, Theme.S(4)))
        {
            using var fill = new SolidBrush(Checked ? (_hover ? Theme.AccentHover : Theme.Accent) : Theme.Surface2);
            g.FillPath(fill, path);
            using var pen = new Pen(Checked ? Theme.Accent : _hover ? Theme.Text : Theme.Muted);
            g.DrawPath(pen, path);
        }
        if (Checked)
        {
            using var pen = new Pen(Theme.AccentText, Math.Max(2f, Theme.S(2))) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
            float b = Box;
            g.DrawLines(pen, new[]
            {
                new PointF(1 + b * 0.25f, y + b * 0.52f), new PointF(1 + b * 0.43f, y + b * 0.70f), new PointF(1 + b * 0.76f, y + b * 0.32f),
            });
        }
        if (Text.Length > 0)
        {
            var tr = new Rectangle(Box + Gap, 0, Width - Box - Gap, Height);
            TextRenderer.DrawText(g, Text, Font, tr, Enabled ? ForeColor : Theme.Muted, TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis);
        }
        if (Focused && ShowFocusCues)
        {
            using var p = new Pen(Theme.Accent) { DashStyle = DashStyle.Dot };
            g.DrawRectangle(p, 0, y - 1, Box + 1, Box + 1);
        }
    }
}

/// <summary>Gold circle with a step number.</summary>
internal sealed class StepBadge : Control
{
    public StepBadge(int n)
    {
        Text = n.ToString();
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
        Font = Theme.Caption;
        Size = new Size(Theme.S(22), Theme.S(22));
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(ModernButton.EffectiveBack(Parent));
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var b = new SolidBrush(Theme.Accent);
        g.FillEllipse(b, 0, 0, Width - 1, Height - 1);
        TextRenderer.DrawText(g, Text, Font, ClientRectangle, Theme.AccentText, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
    }
}
