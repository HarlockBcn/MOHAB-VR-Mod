using System.Drawing.Drawing2D;
using System.Text.RegularExpressions;

namespace MOHABPlus;

internal sealed record FeatureItem(string Title, string Text);
internal sealed record FeatureCategory(string Name, List<FeatureItem> Items);
internal sealed record FeatureGroup(string Name, List<FeatureCategory> Categories);

/// <summary>Parses FEATURES.md (embedded at build time): "## Group", "### Category", "- **Title** - text".</summary>
internal static class FeatureCatalog
{
    private static readonly Regex ItemRx = new(@"^[-*]\s+\*\*(?<t>.+?)\*\*\s*(?:[-–—:]\s*)?(?<d>.*)$", RegexOptions.Compiled);

    public static List<FeatureGroup> Load()
    {
        using var s = typeof(FeatureCatalog).Assembly.GetManifestResourceStream("MOHABPlus.FEATURES.md");
        return s == null ? new() : Parse(new StreamReader(s).ReadToEnd());
    }

    public static List<FeatureGroup> Parse(string md)
    {
        md = Regex.Replace(md, "<!--.*?-->", "", RegexOptions.Singleline);
        var groups = new List<FeatureGroup>();
        FeatureGroup? g = null;
        FeatureCategory? c = null;
        foreach (var raw in md.Split('\n'))
        {
            string line = raw.Trim();
            if (line.StartsWith("### ")) { g ??= Add(groups, "Features"); c = new(line[4..].Trim(), new()); g.Categories.Add(c); }
            else if (line.StartsWith("## ")) { g = Add(groups, line[3..].Trim()); c = null; }
            else if (ItemRx.Match(line) is { Success: true } m)
            {
                g ??= Add(groups, "Features");
                if (c == null) { c = new("General", new()); g.Categories.Add(c); }
                c.Items.Add(new(m.Groups["t"].Value.Trim(), Clean(m.Groups["d"].Value)));
            }
        }
        groups.RemoveAll(x => x.Categories.Count == 0);
        return groups;
    }

    private static FeatureGroup Add(List<FeatureGroup> groups, string name) { var g = new FeatureGroup(name, new()); groups.Add(g); return g; }

    /// <summary>Strips inline markdown (*em*, **bold**, `code`) for plain-text display.</summary>
    private static string Clean(string s) => Regex.Replace(s, @"(\*\*|\*|`)", "").Trim();
}

/// <summary>Scrollable, owner-drawn list of features grouped by category in two columns of cards.</summary>
internal sealed class FeatureListView : ScrollableControl
{
    private readonly List<FeatureGroup> _groups;
    private int _contentHeight;

    public FeatureListView(List<FeatureGroup> groups)
    {
        _groups = groups;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        BackColor = Theme.Bg;
        AutoScroll = true;
        Theme.DarkScrollBars(this);
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        UpdateScrollSize();
    }

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        base.OnMouseWheel(e);
        Invalidate();
    }

    protected override void OnScroll(ScrollEventArgs se)
    {
        base.OnScroll(se);
        Invalidate();
    }

    private void UpdateScrollSize()
    {
        using var g = CreateGraphics();
        int h = Arrange(g, draw: false);
        if (h != _contentHeight) { _contentHeight = h; AutoScrollMinSize = new Size(0, h); }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.Clear(BackColor);
        e.Graphics.TranslateTransform(0, AutoScrollPosition.Y);
        Arrange(e.Graphics, draw: true);
    }

    /// <summary>Lays out (and optionally draws) the whole list; returns the content height.</summary>
    private int Arrange(Graphics g, bool draw)
    {
        int pad = Theme.S(20), gap = Theme.S(12);
        int width = ClientSize.Width - pad * 2;
        if (width < Theme.S(200)) return 0;
        int columns = width >= Theme.S(640) ? 2 : 1;
        int colW = (width - gap * (columns - 1)) / columns;
        int y = Theme.S(10);
        if (draw) { g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit; }

        foreach (var group in _groups)
        {
            // Group title with item count
            int count = group.Categories.Sum(c => c.Items.Count);
            string title = group.Name.ToUpperInvariant();
            var ts = TextRenderer.MeasureText(g, title, Theme.Big, Size.Empty, TextFormatFlags.NoPadding);
            if (draw)
            {
                TextRenderer.DrawText(g, title, Theme.Big, new Point(pad, y), Theme.Text, TextFormatFlags.NoPadding | TextFormatFlags.PreserveGraphicsTranslateTransform);
                string badge = count.ToString();
                var bs = TextRenderer.MeasureText(g, badge, Theme.Caption, Size.Empty, TextFormatFlags.NoPadding);
                var br = new Rectangle(pad + ts.Width + Theme.S(10), y + (ts.Height - bs.Height - Theme.S(6)) / 2, bs.Width + Theme.S(14), bs.Height + Theme.S(6));
                using var path = Theme.Round(br, br.Height / 2f);
                using var b = new SolidBrush(Theme.Accent);
                g.FillPath(b, path);
                TextRenderer.DrawText(g, badge, Theme.Caption, br, Theme.AccentText, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.PreserveGraphicsTranslateTransform);
            }
            y += ts.Height + Theme.S(12);

            // Category cards, placed in the shortest column (masonry)
            var colY = Enumerable.Repeat(y, columns).ToArray();
            foreach (var cat in group.Categories)
            {
                int col = Array.IndexOf(colY, colY.Min());
                int x = pad + col * (colW + gap);
                colY[col] += DrawCard(g, cat, x, colY[col], colW, draw) + gap;
            }
            y = colY.Max() + Theme.S(10);
        }
        return y + Theme.S(10);
    }

    private int DrawCard(Graphics g, FeatureCategory cat, int x, int y, int w, bool draw)
    {
        int ip = Theme.S(14);                 // inner padding
        int dot = Theme.S(6), textX = x + ip + dot + Theme.S(10);
        int textW = w - (textX - x) - ip;
        // GDI text ignores Graphics transforms unless told to keep the (scroll) translation.
        const TextFormatFlags wrap = TextFormatFlags.WordBreak | TextFormatFlags.NoPadding | TextFormatFlags.TextBoxControl | TextFormatFlags.PreserveGraphicsTranslateTransform;

        // Measure
        var capSize = TextRenderer.MeasureText(g, cat.Name.ToUpperInvariant(), Theme.Caption, Size.Empty, TextFormatFlags.NoPadding);
        int h = ip + capSize.Height + Theme.S(10);
        var rows = new List<(FeatureItem item, int titleH, int textH)>();
        foreach (var it in cat.Items)
        {
            int th = TextRenderer.MeasureText(g, it.Title, Theme.Bold, new Size(textW, 0), wrap).Height;
            int dh = it.Text.Length > 0 ? TextRenderer.MeasureText(g, it.Text, Theme.Body, new Size(textW, 0), wrap).Height : 0;
            rows.Add((it, th, dh));
            h += th + (dh > 0 ? Theme.S(2) + dh : 0) + Theme.S(12);
        }
        h += ip - Theme.S(12);
        if (!draw) return h;

        // Draw
        using (var path = Theme.Round(new RectangleF(x + 0.5f, y + 0.5f, w - 1, h - 1), Theme.S(8)))
        {
            using var b = new SolidBrush(Theme.Surface);
            g.FillPath(b, path);
            using var p = new Pen(Theme.Border);
            g.DrawPath(p, path);
        }
        int cy = y + ip;
        TextRenderer.DrawText(g, cat.Name.ToUpperInvariant(), Theme.Caption, new Point(x + ip, cy), Theme.Accent, TextFormatFlags.NoPadding | TextFormatFlags.PreserveGraphicsTranslateTransform);
        cy += capSize.Height + Theme.S(10);
        using var dotBrush = new SolidBrush(Theme.Accent);
        foreach (var (item, th, dh) in rows)
        {
            int lineH = TextRenderer.MeasureText(g, "A", Theme.Bold, Size.Empty, TextFormatFlags.NoPadding).Height;
            g.FillEllipse(dotBrush, x + ip, cy + (lineH - dot) / 2, dot, dot);
            TextRenderer.DrawText(g, item.Title, Theme.Bold, new Rectangle(textX, cy, textW, th), Theme.Text, wrap);
            cy += th;
            if (dh > 0)
            {
                cy += Theme.S(2);
                TextRenderer.DrawText(g, item.Text, Theme.Body, new Rectangle(textX, cy, textW, dh), Theme.Muted, wrap);
                cy += dh;
            }
            cy += Theme.S(12);
        }
        return h;
    }
}
