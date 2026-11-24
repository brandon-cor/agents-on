using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace AgentsOn.Windows;

internal sealed class ModernTheme
{
    private static readonly string FontFamilyName = FindFontFamily();

    public bool IsDark { get; }
    public bool HighContrast { get; }
    public Color Surface { get; }
    public Color Input { get; }
    public Color Text { get; }
    public Color Muted { get; }
    public Color Border { get; }
    public Color Hover { get; }
    public Color Accent { get; }
    public Color AccentText { get; }
    public Color Error { get; }

    private ModernTheme(bool dark, bool highContrast)
    {
        IsDark = dark;
        HighContrast = highContrast;
        if (highContrast)
        {
            Surface = SystemColors.Menu;
            Input = SystemColors.Window;
            Text = SystemColors.MenuText;
            Muted = SystemColors.GrayText;
            Border = SystemColors.WindowFrame;
            Hover = SystemColors.Highlight;
            Accent = SystemColors.Highlight;
            AccentText = SystemColors.HighlightText;
            Error = SystemColors.MenuText;
            return;
        }

        Surface = dark ? Color.FromArgb(0x20, 0x20, 0x20) : Color.FromArgb(0xF9, 0xF9, 0xF9);
        Input = dark ? Color.FromArgb(0x34, 0x34, 0x34) : Color.White;
        Text = dark ? Color.White : Color.FromArgb(0x1B, 0x1B, 0x1B);
        Muted = dark ? Color.FromArgb(0xBD, 0xBD, 0xBD) : Color.FromArgb(0x61, 0x61, 0x61);
        Border = dark ? Color.FromArgb(0x4C, 0x4C, 0x4C) : Color.FromArgb(0xDE, 0xDE, 0xDE);
        Hover = dark ? Color.FromArgb(0x31, 0x31, 0x31) : Color.FromArgb(0xED, 0xED, 0xED);
        Accent = dark ? Color.FromArgb(0x60, 0xCD, 0xFF) : Color.FromArgb(0x00, 0x67, 0xC0);
        AccentText = dark ? Color.FromArgb(0x00, 0x24, 0x3A) : Color.White;
        Error = dark ? Color.FromArgb(0xFF, 0x99, 0xA4) : Color.FromArgb(0xC4, 0x2B, 0x1C);
    }

    public static ModernTheme Current
    {
        get
        {
            bool dark = false;
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
                dark = key?.GetValue("AppsUseLightTheme") is int value && value == 0;
            }
            catch
            {
                // A missing or restricted preference must not prevent the controls opening.
            }
            return new ModernTheme(dark, SystemInformation.HighContrast);
        }
    }

    // Explicit palettes make previews deterministic without changing Windows settings.
    public static ModernTheme For(bool dark) => new(dark, highContrast: false);

    public Font CreateFont(float points, FontStyle style = FontStyle.Regular)
    {
        try { return new Font(FontFamilyName, points, style, GraphicsUnit.Point); }
        catch (ArgumentException)
        {
            return new Font(SystemFonts.MessageBoxFont?.FontFamily ?? FontFamily.GenericSansSerif, points, style, GraphicsUnit.Point);
        }
    }

    public static int Scale(int logicalPixels, int deviceDpi = 96) =>
        (int)Math.Round(logicalPixels * (deviceDpi > 0 ? deviceDpi : 96) / 96d, MidpointRounding.AwayFromZero);

    public static GraphicsPath RoundedRect(RectangleF rect, float radius)
    {
        var path = new GraphicsPath();
        if (rect.Width <= 0 || rect.Height <= 0) return path;
        radius = float.IsFinite(radius) ? Math.Clamp(radius, 0, Math.Min(rect.Width, rect.Height) / 2) : 0;
        if (radius == 0)
        {
            path.AddRectangle(rect);
            return path;
        }

        var diameter = radius * 2;
        path.AddArc(rect.Left, rect.Top, diameter, diameter, 180, 90);
        path.AddArc(rect.Right - diameter, rect.Top, diameter, diameter, 270, 90);
        path.AddArc(rect.Right - diameter, rect.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rect.Left, rect.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }

    public void ApplyWindow(Form form)
    {
        // These DWM attributes are documented from Windows 11 build 22000 onward.
        // Leave the normal form frame intact and let unsupported hosts ignore them.
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) || form.IsDisposed || !form.IsHandleCreated) return;
        try
        {
            int dark = IsDark && !HighContrast ? 1 : 0;
            int corners = HighContrast ? 0 : 2; // Default in contrast themes; otherwise prefer rounded corners.
            int border = HighContrast ? unchecked((int)0xFFFFFFFF) : Border.R | Border.G << 8 | Border.B << 16;
            _ = DwmSetWindowAttribute(form.Handle, 20, ref dark, sizeof(int));
            _ = DwmSetWindowAttribute(form.Handle, 33, ref corners, sizeof(int));
            _ = DwmSetWindowAttribute(form.Handle, 34, ref border, sizeof(int));
        }
        catch
        {
            // Frame decoration is optional; the dialog must remain usable without DWM.
        }
    }

    private static string FindFontFamily()
    {
        foreach (var name in new[] { "Segoe UI Variable Text", "Segoe UI" })
        {
            try
            {
                using var family = new FontFamily(name);
                return family.Name;
            }
            catch (ArgumentException) { }
        }
        return FontFamily.GenericSansSerif.Name;
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
}
