using System.ComponentModel;
using System.Drawing.Drawing2D;

namespace AgentsOn.Windows;

/// <summary>Keeps native menu keyboard/accessibility behavior with Windows 11-style surfaces.</summary>
internal sealed class ModernContextMenu : ContextMenuStrip
{
    private ModernTheme theme = ModernTheme.Current;
    private Font? menuFont;
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal ModernTheme? PreviewTheme { get; set; }

    public ModernContextMenu()
    {
        ShowImageMargin = false;
        ShowCheckMargin = true;
        DropShadowEnabled = true;
        AccessibleName = "Agents On options";
        SetStyle(ControlStyles.OptimizedDoubleBuffer, true);
        ApplyTheme(theme);
    }

    protected override void OnOpening(CancelEventArgs e)
    {
        ApplyTheme(PreviewTheme ?? ModernTheme.Current);
        base.OnOpening(e);
        PerformLayout();
    }

    protected override void OnOpened(EventArgs e)
    {
        UpdateShape();
        base.OnOpened(e);
    }

    private void ApplyTheme(ModernTheme value)
    {
        theme = value;
        var previous = menuFont;
        menuFont = theme.CreateFont(10);
        Font = menuFont;
        previous?.Dispose();
        BackColor = theme.Surface;
        ForeColor = theme.Text;
        Renderer = new ModernMenuRenderer(theme);
        var scale = DeviceDpi / 96f;
        Padding = new Padding((int)(6 * scale), (int)(7 * scale), (int)(6 * scale), (int)(7 * scale));
        foreach (ToolStripItem item in Items)
        {
            item.AutoSize = false;
            item.Size = new Size((int)(320 * scale), (int)((item is ToolStripSeparator ? 10 : 36) * scale));
            item.Padding = item is ToolStripSeparator ? Padding.Empty : new Padding(0, 4, (int)(8 * scale), 4);
            item.ForeColor = theme.Text;
        }
        UpdateShape();
    }

    protected override void OnSizeChanged(EventArgs e)
    {
        base.OnSizeChanged(e);
        if (theme is not null) UpdateShape();
    }

    private void UpdateShape()
    {
        if (Width <= 0 || Height <= 0) return;
        var previous = Region;
        if (theme.HighContrast) Region = null;
        else
        {
            using var path = ModernTheme.RoundedRect(new RectangleF(0, 0, Width, Height), 10 * DeviceDpi / 96f);
            Region = new Region(path);
        }
        previous?.Dispose();
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        if (disposing) { menuFont?.Dispose(); menuFont = null; }
    }
}

internal sealed class ModernMenuRenderer(ModernTheme theme) : ToolStripProfessionalRenderer
{
    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e)
    {
        e.Graphics.Clear(theme.Surface);
    }

    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e)
    {
        var smoothing = e.Graphics.SmoothingMode;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        var bounds = new RectangleF(.5f, .5f, e.ToolStrip.Width - 1, e.ToolStrip.Height - 1);
        using var path = ModernTheme.RoundedRect(bounds, theme.HighContrast ? 0 : 10 * e.ToolStrip.DeviceDpi / 96f);
        using var pen = new Pen(theme.Border);
        e.Graphics.DrawPath(pen, path);
        e.Graphics.SmoothingMode = smoothing;
    }

    protected override void OnRenderImageMargin(ToolStripRenderEventArgs e) { }

    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
    {
        if (!e.Item.Selected || !e.Item.Enabled) return;
        var scale = e.ToolStrip!.DeviceDpi / 96f;
        var smoothing = e.Graphics.SmoothingMode;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = ModernTheme.RoundedRect(new RectangleF(2 * scale, 1 * scale, e.Item.Width - 4 * scale, e.Item.Height - 2 * scale), theme.HighContrast ? 0 : 5 * scale);
        using var fill = new SolidBrush(theme.Hover);
        e.Graphics.FillPath(fill, path);
        e.Graphics.SmoothingMode = smoothing;
    }

    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
    {
        var color = !e.Item.Enabled ? theme.Muted : theme.HighContrast && e.Item.Selected ? SystemColors.HighlightText : theme.Text;
        TextRenderer.DrawText(e.Graphics, e.Text, e.TextFont ?? e.Item.Font, e.TextRectangle, color, e.TextFormat);
    }

    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
    {
        var inset = (int)(8 * e.ToolStrip!.DeviceDpi / 96f);
        using var pen = new Pen(theme.Border);
        e.Graphics.DrawLine(pen, inset, e.Item.Height / 2, e.Item.Width - inset, e.Item.Height / 2);
    }

    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e)
    {
        var scale = e.ToolStrip!.DeviceDpi / 96f;
        var size = 16 * scale;
        var bounds = new RectangleF(e.ImageRectangle.Left + (e.ImageRectangle.Width - size) / 2f, (e.Item.Height - size) / 2f, size, size);
        var smoothing = e.Graphics.SmoothingMode;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = ModernTheme.RoundedRect(bounds, theme.HighContrast ? 0 : 3 * scale);
        using var fill = new SolidBrush(theme.Accent);
        e.Graphics.FillPath(fill, path);
        using var pen = new Pen(theme.AccentText, 1.7f * scale) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        e.Graphics.DrawLines(pen, new PointF[] { new(bounds.Left + 4 * scale, bounds.Top + 8 * scale), new(bounds.Left + 7 * scale, bounds.Top + 11 * scale), new(bounds.Left + 12 * scale, bounds.Top + 5 * scale) });
        e.Graphics.SmoothingMode = smoothing;
    }
}
