using System.ComponentModel;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using AgentsOn.Core;

namespace AgentsOn.Windows;

internal sealed class DurationForm : Form
{
    private readonly TextBox hours = new() { Text = "0", AccessibleName = "Hours", BorderStyle = BorderStyle.None, TabIndex = 0 };
    private readonly TextBox minutes = new() { Text = "0", AccessibleName = "Minutes", BorderStyle = BorderStyle.None, TabIndex = 0 };
    private readonly Label heading = new() { Text = "Keep agents on for how long?", AutoSize = false, TabStop = false };
    private readonly Label hoursLabel = new() { Text = "&Hours", AutoSize = true, TabStop = false, TabIndex = 0 };
    private readonly Label minutesLabel = new() { Text = "&Minutes", AutoSize = true, TabStop = false, TabIndex = 1 };
    private readonly Label error = new() { AutoSize = false, AccessibleRole = AccessibleRole.Alert, TabStop = false };
    private readonly DurationEntryPanel hoursSurface;
    private readonly DurationEntryPanel minutesSurface;
    private readonly DurationActionButton cancel;
    private readonly DurationActionButton start;
    private readonly DurationActionButton close;
    private readonly List<Font> ownedFonts = [];
    private readonly bool followSystem;
    private ModernTheme theme;
    private bool disposed;

    public TimeSpan Duration { get; private set; }
    internal TextBox HoursInput => hours;
    internal TextBox MinutesInput => minutes;
    internal string ValidationMessage => error.Text;

    public DurationForm() : this(ModernTheme.Current, followSystem: true) { }
    internal DurationForm(ModernTheme theme) : this(theme, followSystem: false) { }

    private DurationForm(ModernTheme theme, bool followSystem)
    {
        this.theme = theme;
        this.followSystem = followSystem;
        AutoScaleDimensions = new SizeF(96, 96);
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(440, 340);
        FormBorderStyle = FormBorderStyle.None;
        Text = "Custom duration";
        AccessibleName = Text;
        AccessibleRole = AccessibleRole.Dialog;
        ShowIcon = false;
        ShowInTaskbar = false;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        DoubleBuffered = true;
        Font = OwnFont(10.5f);

        heading.Font = OwnFont(17, FontStyle.Bold);
        heading.SetBounds(28, 31, 338, 64);
        hoursLabel.SetBounds(28, 117, 180, 22);
        minutesLabel.SetBounds(232, 117, 180, 22);
        hours.Font = OwnFont(22);
        minutes.Font = hours.Font;
        hours.AccessibleDescription = "Hours to keep your computer awake.";
        minutes.AccessibleDescription = "Minutes to add to the hours.";
        hoursSurface = new DurationEntryPanel(hours, theme) { TabIndex = 0 };
        minutesSurface = new DurationEntryPanel(minutes, theme) { TabIndex = 1 };
        hoursSurface.SetBounds(28, 145, 180, 62);
        minutesSurface.SetBounds(232, 145, 180, 62);
        error.SetBounds(28, 221, 384, 36);
        error.Font = OwnFont(9.5f);
        error.UseMnemonic = false;
        error.LiveSetting = System.Windows.Forms.Automation.AutomationLiveSetting.Assertive;
        error.AccessibleName = "Duration validation";

        cancel = new DurationActionButton("&Cancel", theme) { TabIndex = 2, DialogResult = DialogResult.Cancel };
        start = new DurationActionButton("&Start timer", theme, primary: true) { TabIndex = 3 };
        close = new DurationActionButton("", theme, close: true) { TabIndex = 4, AccessibleName = "Close" };
        cancel.SetBounds(178, 278, 104, 40);
        start.SetBounds(294, 278, 118, 40);
        close.SetBounds(390, 16, 32, 32);
        cancel.Click += (_, _) => CancelDuration();
        close.Click += (_, _) => CancelDuration();
        start.Click += (_, _) => SubmitDuration();
        AcceptButton = start;
        CancelButton = cancel;

        Controls.AddRange([heading, hoursLabel, minutesLabel, hoursSurface, minutesSurface, error, cancel, start, close]);
        foreach (var field in new[] { hours, minutes })
        {
            field.Leave += (_, _) => { if (string.IsNullOrWhiteSpace(field.Text)) field.Text = "0"; };
            field.TextChanged += (_, _) => ClearValidation();
        }
        heading.MouseDown += DragHeader;
        ApplyTheme(theme);
        if (followSystem) SystemEvents.UserPreferenceChanged += PreferencesChanged;
    }

    private Font OwnFont(float size, FontStyle style = FontStyle.Regular)
    {
        var value = theme.CreateFont(size, style);
        ownedFonts.Add(value);
        return value;
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        UpdateWindowRegion();
        theme.ApplyWindow(this);
    }

    protected override void OnSizeChanged(EventArgs e)
    {
        base.OnSizeChanged(e);
        UpdateWindowRegion();
    }

    private void UpdateWindowRegion()
    {
        if (theme is null || ClientSize.Width <= 0 || ClientSize.Height <= 0) return;
        var previous = Region;
        if (theme.HighContrast) Region = null;
        else
        {
            using var outline = ModernTheme.RoundedRect(ClientRectangle, ModernTheme.Scale(12, DeviceDpi));
            Region = new Region(outline);
        }
        previous?.Dispose();
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        ActiveControl = hours;
        hours.Focus();
        hours.SelectAll();
    }

    private void ApplyTheme(ModernTheme value)
    {
        theme = value;
        BackColor = theme.Surface;
        ForeColor = theme.Text;
        heading.ForeColor = theme.Text;
        hoursLabel.ForeColor = minutesLabel.ForeColor = theme.Muted;
        error.ForeColor = theme.Error;
        hoursSurface.ApplyTheme(theme);
        minutesSurface.ApplyTheme(theme);
        foreach (var button in new[] { cancel, start, close }) button.ApplyTheme(theme);
        UpdateWindowRegion();
        if (IsHandleCreated) theme.ApplyWindow(this);
        Invalidate(true);
    }

    private void PreferencesChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (IsDisposed || Disposing || !IsHandleCreated) return;
        try { BeginInvoke(() => { if (!IsDisposed && !Disposing) ApplyTheme(ModernTheme.Current); }); }
        catch (InvalidOperationException) when (IsDisposed || Disposing) { }
    }

    internal bool SubmitDuration()
    {
        if (SessionController.ParseDuration(hours.Text, minutes.Text) is not { } value)
        {
            error.Text = "Enter a valid duration greater than zero.";
            error.AccessibleName = error.Text;
            hoursSurface.Invalid = minutesSurface.Invalid = true;
            hours.Focus();
            hours.SelectAll();
            return false;
        }
        Duration = value;
        DialogResult = DialogResult.OK;
        Close();
        return true;
    }

    private void ClearValidation()
    {
        error.Text = "";
        error.AccessibleName = "Duration validation";
        hoursSurface.Invalid = minutesSurface.Invalid = false;
    }

    private void CancelDuration() { DialogResult = DialogResult.Cancel; Close(); }
    internal bool ProcessDialogKeyForTest(Keys key) => ProcessDialogKey(key);

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var outline = ModernTheme.RoundedRect(new RectangleF(.5f, .5f, ClientSize.Width - 1, ClientSize.Height - 1), theme.HighContrast ? 0 : ModernTheme.Scale(12, DeviceDpi));
        using var pen = new Pen(theme.Border);
        e.Graphics.DrawPath(pen, outline);
    }

    protected override void WndProc(ref Message message)
    {
        base.WndProc(ref message);
        if (message.Msg != 0x0084 || message.Result != (IntPtr)1) return;
        var position = message.LParam.ToInt64();
        var point = PointToClient(new Point(unchecked((short)position), unchecked((short)(position >> 16))));
        if (point.Y < ModernTheme.Scale(100, DeviceDpi) && (close is null || !close.Bounds.Contains(point))) message.Result = (IntPtr)2;
    }

    private void DragHeader(object? sender, MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        ReleaseCapture();
        SendMessage(Handle, 0x00A1, (IntPtr)2, IntPtr.Zero);
    }

    [DllImport("user32.dll")] private static extern bool ReleaseCapture();
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr parameter, IntPtr location);

    protected override void Dispose(bool disposing)
    {
        if (disposing && !disposed)
        {
            disposed = true;
            if (followSystem) SystemEvents.UserPreferenceChanged -= PreferencesChanged;
            base.Dispose(true);
            foreach (var font in ownedFonts) font.Dispose();
            return;
        }
        base.Dispose(disposing);
    }
}

internal sealed class DurationEntryPanel : Panel
{
    private readonly TextBox field;
    private ModernTheme theme;
    private bool invalid;
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal bool Invalid { set { invalid = value; Invalidate(); } }

    internal DurationEntryPanel(TextBox field, ModernTheme theme)
    {
        this.field = field;
        this.theme = theme;
        DoubleBuffered = true;
        TabStop = false;
        Controls.Add(field);
        field.Enter += (_, _) => Invalidate();
        field.Leave += (_, _) => Invalidate();
        ApplyTheme(theme);
    }

    internal void ApplyTheme(ModernTheme value)
    {
        theme = value;
        BackColor = theme.Surface;
        field.BackColor = theme.Input;
        field.ForeColor = theme.HighContrast ? SystemColors.WindowText : theme.Text;
        Invalidate();
    }

    protected override void OnLayout(LayoutEventArgs e)
    {
        base.OnLayout(e);
        var inset = ModernTheme.Scale(16, DeviceDpi);
        field.SetBounds(inset, Math.Max(0, (ClientSize.Height - field.PreferredHeight) / 2), Math.Max(0, ClientSize.Width - 2 * inset), field.PreferredHeight);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = ModernTheme.RoundedRect(new RectangleF(1, 1, ClientSize.Width - 2, ClientSize.Height - 2), theme.HighContrast ? 0 : ModernTheme.Scale(8, DeviceDpi));
        using var fill = new SolidBrush(theme.Input);
        e.Graphics.FillPath(fill, path);
        using var border = new Pen(invalid ? theme.Error : field.Focused ? theme.Accent : theme.Border, field.Focused || invalid ? 2 : 1);
        e.Graphics.DrawPath(border, path);
    }
}

internal sealed class DurationActionButton : Button
{
    private ModernTheme theme;
    private readonly bool primary;
    private readonly bool close;
    private bool hovered;
    private bool pressed;

    internal DurationActionButton(string text, ModernTheme theme, bool primary = false, bool close = false)
    {
        this.theme = theme;
        this.primary = primary;
        this.close = close;
        Text = text;
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        UseVisualStyleBackColor = false;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
        ApplyTheme(theme);
    }

    internal void ApplyTheme(ModernTheme value) { theme = value; BackColor = theme.Surface; ForeColor = primary ? theme.AccentText : theme.Text; Invalidate(); }
    protected override void OnMouseEnter(EventArgs e) { hovered = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hovered = pressed = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) pressed = true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { pressed = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { pressed = false; Invalidate(); base.OnLostFocus(e); }
    protected override void OnKeyDown(KeyEventArgs e) { if (e.KeyCode == Keys.Space) pressed = true; Invalidate(); base.OnKeyDown(e); }
    protected override void OnKeyUp(KeyEventArgs e) { pressed = false; Invalidate(); base.OnKeyUp(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        var color = primary ? (hovered ? ControlPaint.Light(theme.Accent, .06f) : theme.Accent) : hovered ? theme.Hover : theme.Input;
        var textColor = ForeColor;
        if (close && !hovered) color = theme.Surface;
        if (pressed) color = ControlPaint.Dark(color, .08f);
        if (theme.HighContrast)
        {
            if (primary || hovered || pressed) { color = SystemColors.Highlight; textColor = SystemColors.HighlightText; }
            else if (close) { color = theme.Surface; textColor = theme.Text; }
            else { color = SystemColors.Window; textColor = SystemColors.WindowText; }
        }
        using var path = ModernTheme.RoundedRect(new RectangleF(.5f, .5f, Width - 1, Height - 1), theme.HighContrast ? 0 : ModernTheme.Scale(close ? 6 : 8, DeviceDpi));
        using var fill = new SolidBrush(color);
        e.Graphics.FillPath(fill, path);
        if (!close && !primary)
        {
            using var border = new Pen(theme.Border);
            e.Graphics.DrawPath(border, path);
        }
        if (close)
        {
            var center = new PointF(Width / 2f, Height / 2f);
            var half = ModernTheme.Scale(4, DeviceDpi);
            using var pen = new Pen(textColor, ModernTheme.Scale(1, DeviceDpi));
            e.Graphics.DrawLine(pen, center.X - half, center.Y - half, center.X + half, center.Y + half);
            e.Graphics.DrawLine(pen, center.X + half, center.Y - half, center.X - half, center.Y + half);
        }
        else
        {
            var flags = TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine;
            if (!ShowKeyboardCues) flags |= TextFormatFlags.HidePrefix;
            TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, textColor, flags);
        }
        if (Focused && ShowFocusCues)
        {
            var focus = ClientRectangle;
            focus.Inflate(-ModernTheme.Scale(5, DeviceDpi), -ModernTheme.Scale(5, DeviceDpi));
            ControlPaint.DrawFocusRectangle(e.Graphics, focus, textColor, color);
        }
    }
}
