using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Reflection;
using System.Text.Json;
using AgentsOn.Core;

internal static class Preview
{
    private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
    private sealed class FakeLease : IAwakeLease
    {
        public bool IsHeld { get; private set; }
        public void Acquire(bool keepLidAwake) => IsHeld = true;
        public void Release() => IsHeld = false;
        public bool IsPolicyIntact() => true;
    }
    [STAThread]
    private static void Main(string[] args)
    {
        var output = Path.GetFullPath(args[0]);Directory.CreateDirectory(output);
        var assembly = Assembly.Load("AgentsOn");
        assembly.GetTypes().Single(t => t.Name == "ApplicationConfiguration")
            .GetMethod("Initialize", BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic)!.Invoke(null, null);
        var version = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()!.InformationalVersion.Split('+')[0];
        var trayType = assembly.GetType("AgentsOn.Windows.TrayContext", true)!;
        var themeType = assembly.GetType("AgentsOn.Windows.ModernTheme", true)!;
        var durationType = assembly.GetType("AgentsOn.Windows.DurationForm", true)!;
        using var context = (ApplicationContext)Activator.CreateInstance(trayType, new object[] { new FakeLease(), true })!;
        ((System.Windows.Forms.Timer)trayType.GetField("tick", Private)!.GetValue(context)!).Stop();
        var menu = (ContextMenuStrip)trayType.GetField("menu", Private)!.GetValue(context)!;
        using var offIcon = ((Icon)trayType.GetField("offIcon", Private)!.GetValue(context)!).ToBitmap();
        using var onIcon = ((Icon)trayType.GetField("onIcon", Private)!.GetValue(context)!).ToBitmap();
        var sizes = new List<object>();
        foreach (var dark in new[] { false, true })
        {
            var name = dark ? "dark" : "light";
            var theme = themeType.GetMethod("For")!.Invoke(null, new object[] { dark })!;
            menu.GetType().GetProperty("PreviewTheme", Private)!.SetValue(menu, theme);
            using (var off = CaptureMenu(menu)) off.Save(Path.Combine(output, name + "-menu-off.png"), ImageFormat.Png);
            ((ToolStripMenuItem)menu.Items[2]).PerformClick();Thread.Sleep(1200);
            using var timed = CaptureMenu(menu);
            timed.Save(Path.Combine(output, name + "-menu-timer.png"), ImageFormat.Png);
            trayType.GetMethod("Toggle", Private)!.Invoke(context, null);
            using var form = (Form)Activator.CreateInstance(durationType, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic, null, new object[] { theme }, null)!;
            form.Show();form.PerformLayout();Application.DoEvents();
            using var custom = Capture(form);
            custom.Save(Path.Combine(output, name + "-custom-duration.png"), ImageFormat.Png);
            sizes.Add(new { theme = name, dpi = form.DeviceDpi, menu = new { timed.Width, timed.Height }, dialog = new { custom.Width, custom.Height } });
            form.Close();
            Overview(Path.Combine(output, "windows-modern-" + name + ".png"), version, dark, timed, custom, offIcon, onIcon);
        }
        File.WriteAllText(Path.Combine(output, "capture.json"), JsonSerializer.Serialize(new
        {
            sourceCommit = Environment.GetEnvironmentVariable("GITHUB_SHA") ?? "local",
            version, os = Environment.OSVersion.VersionString, runtime = Environment.Version.ToString(), sizes,
            method = "Actual Windows controls rendered with Control.DrawToBitmap and their window regions; simulated power backend, no desktop/taskbar capture."
        }, new JsonSerializerOptions { WriteIndented = true }));
        Console.WriteLine("Captured actual light/dark Windows menus and duration dialogs.");
    }
    private static Bitmap CaptureMenu(ContextMenuStrip menu)
    {
        menu.Show(new Point(100, 100));menu.PerformLayout();Application.DoEvents();
        var image = Capture(menu);menu.Close();return image;
    }
    private static Bitmap Capture(Control control)
    {
        using var raw = new Bitmap(control.Width, control.Height);
        control.DrawToBitmap(raw, new Rectangle(Point.Empty, raw.Size));
        var image = new Bitmap(raw.Width, raw.Height);
        using var graphics = Graphics.FromImage(image);
        graphics.Clear(Color.Transparent);
        if (control.Region is { } region) graphics.SetClip(region, CombineMode.Replace);
        graphics.DrawImageUnscaled(raw, 0, 0);
        return image;
    }
    private static void Overview(string path, string version, bool dark, Bitmap menu, Bitmap custom, Bitmap off, Bitmap on)
    {
        const int pad = 32, gap = 32;
        var width = pad * 2 + menu.Width + custom.Width + gap;
        var height = 240 + Math.Max(menu.Height, custom.Height) + 56;
        using var image = new Bitmap(width, height);using var g = Graphics.FromImage(image);
        g.Clear(dark ? Color.FromArgb(18, 20, 24) : Color.FromArgb(240, 243, 248));
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        using var title = new Font("Segoe UI", 24, FontStyle.Bold, GraphicsUnit.Pixel);
        using var body = new Font("Segoe UI", 14, FontStyle.Regular, GraphicsUnit.Pixel);
        using var label = new Font("Segoe UI", 15, FontStyle.Bold, GraphicsUnit.Pixel);
        using var ink = new SolidBrush(dark ? Color.White : Color.FromArgb(25, 30, 39));
        using var muted = new SolidBrush(dark ? Color.FromArgb(177, 185, 197) : Color.FromArgb(85, 96, 113));
        g.DrawString("Agents On for Windows", title, ink, pad, 25);
        g.DrawString((dark ? "Dark" : "Light") + " mode · v" + version, body, muted, pad, 65);
        g.DrawImage(off, new Rectangle(pad, 104, 40, 40));g.DrawString("agents off", body, ink, pad + 50, 116);
        g.DrawImage(on, new Rectangle(pad + 208, 104, 40, 40));g.DrawString("agents on", body, ink, pad + 258, 116);
        g.DrawString("Left-click to toggle · Right-click for timers · Status text appears on hover", body, muted, pad, 164);
        var x = pad + menu.Width + gap;
        g.DrawString("Timer menu", label, ink, pad, 207);g.DrawString("Custom duration", label, ink, x, 207);
        g.DrawImageUnscaled(menu, pad, 240);g.DrawImageUnscaled(custom, x, 240);
        g.DrawString("Actual controls captured on Windows. Desktop scaling and shadows may vary.", body, muted, pad, height - 32);
        image.Save(path, ImageFormat.Png);
    }
}
