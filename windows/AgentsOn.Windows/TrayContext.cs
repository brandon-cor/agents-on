using System.Drawing.Drawing2D;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;
using AgentsOn.Core;

namespace AgentsOn.Windows;

internal sealed class Preferences
{
    public bool KeepLidAwake {get;set;}=true;
    private static string PathName => Path.Combine(AppPaths.Data,"settings.json");
    public static Preferences Load()
    {
        try {return JsonSerializer.Deserialize<Preferences>(File.ReadAllText(PathName)) ?? new();}
        catch(FileNotFoundException){return new();}
        catch(DirectoryNotFoundException){return new();}
        catch(JsonException){return new();}
    }
    public void Save()
    {
        Directory.CreateDirectory(AppPaths.Data);
        var temp=PathName+".tmp";
        File.WriteAllText(temp,JsonSerializer.Serialize(this));
        File.Move(temp,PathName,true);
    }
}

internal sealed class TrayContext : ApplicationContext
{
    private readonly Control dispatch=new();
    private readonly NotifyIcon icon=new();
    private readonly ModernContextMenu menu=new();
    private readonly ToolStripMenuItem countdown=new(){Enabled=false};
    private readonly ToolStripSeparator countdownSeparator=new();
    private readonly IAwakeLease lease;
    private readonly SessionController session;
    private readonly Preferences settings;
    private readonly System.Windows.Forms.Timer tick=new(){Interval=250};
    private readonly CancellationTokenSource shutdown=new();
    private readonly Icon onIcon=CreateLight(true),offIcon=CreateLight(false);
    private bool closing;
    private bool disposed;
    private string? previousError;
    public int ExitCode {get;private set;}

    public TrayContext(IAwakeLease? backend=null, bool testMode=false)
    {
        _=dispatch.Handle;
        lease=backend ?? new WindowsAwakeLease();
        settings=testMode ? new Preferences() : Preferences.Load();
        session=new SessionController(lease);
        try {if(lease is WindowsAwakeLease windows)windows.Recover();} catch(Exception ex){previousError=ex.Message;}
        menu.Items.Add(countdown);menu.Items.Add(countdownSeparator);
        foreach(var (title,minutes) in new[]{("30 minutes",30),("1 hour",60),("3 hours",180)})
            menu.Items.Add(title,null,(_,_)=>Run(()=>session.Start(TimeSpan.FromMinutes(minutes),settings.KeepLidAwake)));
        menu.Items.Add("Custom duration…",null,(_,_)=>CustomDuration());
        menu.Items.Add(new ToolStripSeparator());
        var lid=new ToolStripMenuItem("Keep awake with lid closed"){Checked=settings.KeepLidAwake,CheckOnClick=false};
        lid.Click+=(_,_)=>Run(()=>
        {
            var next=!settings.KeepLidAwake;
            if(session.Active) session.Stop();
            settings.KeepLidAwake=next;
            settings.Save();lid.Checked=next;
        });
        menu.Items.Add(lid);
        var heat=new ToolStripMenuItem("Heat cutoff unavailable on Windows"){Enabled=false,ToolTipText="Windows does not provide a reliable live thermal signal on every laptop."};
        menu.Items.Add(heat);
        menu.Items.Add("About / lid settings…",null,(_,_)=>ShowHelp());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit",null,(_,_)=>Quit());
        menu.Opening+=(_,_)=>Refresh();
        icon.Icon=offIcon;icon.Text="agents off";icon.ContextMenuStrip=menu;
        icon.MouseClick+=(_,e)=>{if(e.Button==MouseButtons.Left) Toggle();};
        icon.Visible=true;
        tick.Tick+=(_,_)=>{var pending=session.StopPending;session.Tick();if(pending && !session.StopPending)previousError=null;Refresh();};tick.Start();
        SystemEvents.PowerModeChanged+=PowerChanged;
        Application.ApplicationExit+=OnApplicationExit;
        _=ServeAsync(shutdown.Token);
        Refresh();
        if(previousError!=null) Notify("Restoring lid settings",previousError);
        else if(!testMode && !File.Exists(Path.Combine(AppPaths.Data,"welcome-shown")))
        {
            Directory.CreateDirectory(AppPaths.Data);File.WriteAllText(Path.Combine(AppPaths.Data,"welcome-shown"),"");
            Notify("agents off","Look for the gray light near the clock (or under the ^ arrow). Left-click to toggle; right-click for timers.");
        }
    }
    private void Run(Action action)
    {
        try {action();previousError=null;}
        catch(Exception ex)
        {
            previousError=ex.Message;
            MessageBox.Show(ex.Message,"Agents On",MessageBoxButtons.OK,MessageBoxIcon.Error);
        }
        Refresh();
    }
    private void Refresh()
    {
        if(closing) return;
        var active=session.Active;
        icon.Icon=active ? onIcon:offIcon;
        var error=session.Error ?? previousError;
        var label=active ? "agents on":"agents off";
        var tooltip=label+(error!=null ? (session.StopPending ? " — sleep restoration needs attention":" — could not start keep-awake"):"")+(session.Countdown is { } remaining ? " — "+remaining:"");
        icon.Text=tooltip[..Math.Min(127,tooltip.Length)];
        countdown.Text=session.Countdown ?? (session.StopPending ? "Sleep restoration pending; retrying…":error!=null ? "Keep-awake did not start":label);
        countdown.Visible=session.Deadline!=null || error!=null;
        countdownSeparator.Visible=countdown.Visible;
        if(error!=null && error!=previousError){previousError=error;Notify("Agents On needs attention",error);}
    }
    private void CustomDuration()
    {
        using var form=new DurationForm();
        if(form.ShowDialog()==DialogResult.OK) Run(()=>session.Start(form.Duration,settings.KeepLidAwake));
    }
    private void ShowHelp() => MessageBox.Show(
        "Left-click the green or gray tray light to toggle. Right-click for a timer. If the light is hidden, open the ^ arrow near the clock and drag it into the visible tray.\n\n"+
        "With ‘Keep awake with lid closed’ checked, Agents On temporarily changes both the plugged-in and battery lid actions. Turning it off, ending a timer, or quitting restores the previous values. A recovery helper also restores them if the app exits unexpectedly. Changing that checkbox stops an active session.\n\n"+
        "Windows heat cutoff is unavailable. The app does not remove your screen lock or override a manual Sleep command. Turn it off and verify the laptop is asleep before putting it in a bag.\n\n"+
        "Version "+Program.Version,"Agents On",MessageBoxButtons.OK,MessageBoxIcon.Information);
    private void Notify(string title,string message)
    {
        icon.BalloonTipTitle=title;icon.BalloonTipText=message;icon.ShowBalloonTip(5000);
    }
    private bool StopForQuit()
    {
        try {session.Stop();}
        catch(Exception ex){previousError=ex.Message;Refresh();Notify("Lid settings still need restoring",ex.Message);return false;}
        return true;
    }
    private void FinishQuit() {closing=true;tick.Stop();icon.Visible=false;shutdown.Cancel();ExitThread();}
    private bool Quit() {if(!StopForQuit())return false;FinishQuit();return true;}
    internal void Toggle() => Run(()=>{if(session.Active)session.Stop();else session.Start(null,settings.KeepLidAwake);});
    internal void CheckControls()
    {
        if(session.Active || !icon.Visible) throw new Exception("Tray did not start off and visible.");
        Toggle();if(!session.Active)throw new Exception("Left-click did not start.");
        Toggle();if(session.Active)throw new Exception("Left-click did not stop.");
        ((ToolStripMenuItem)menu.Items[2]).PerformClick();
        if(!session.Active || session.Deadline==null || !session.Countdown!.StartsWith("30m"))throw new Exception("Timer menu did not start a 30-minute session.");
        Refresh();if(icon.Text.StartsWith("agents on")!=true)throw new Exception("Wrong tray label.");
        session.Stop();Refresh();
        foreach(var dark in new[]{false,true})
        {
            menu.PreviewTheme=ModernTheme.For(dark);
            menu.Show(new Point(16,16));
            Application.DoEvents();
            var last=menu.Items[^1];
            if(last.Placement!=ToolStripItemPlacement.Main || last.Bounds.Bottom>menu.ClientSize.Height)
                throw new Exception("The timer menu clips its last option.");
            foreach(ToolStripItem item in menu.Items)
                if(item.Visible && item is ToolStripMenuItem && TextRenderer.MeasureText(item.Text,item.Font).Width+30*menu.DeviceDpi/96>item.Width)
                    throw new Exception("A menu label does not fit its row: "+item.Text);
            menu.Close();
        }
        menu.PreviewTheme=null;
        using var duration=new DurationForm();
        if(duration.ShowIcon)throw new Exception("Custom duration shows a placeholder icon.");
    }
    private void PowerChanged(object? sender,PowerModeChangedEventArgs e)
    {
        if(e.Mode==PowerModes.Suspend && !closing) dispatch.BeginInvoke(()=>{try{session.Stop();}catch(Exception ex){previousError=ex.Message;}Refresh();});
    }
    private void OnApplicationExit(object? sender,EventArgs e)
    {
        // The watchdog takes over a remaining journal after process exit if this attempt fails.
        try {lease.Release();}catch { }
    }
    private async Task ServeAsync(CancellationToken cancellation)
    {
        while(!cancellation.IsCancellationRequested)
        {
            try
            {
                using var pipe=new NamedPipeServerStream(AppPaths.Pipe,PipeDirection.InOut,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous|PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(cancellation).ConfigureAwait(false);
                using var reader=new StreamReader(pipe,Encoding.UTF8,leaveOpen:true);
                using var writer=new StreamWriter(pipe,new UTF8Encoding(false),leaveOpen:true){AutoFlush=true};
                using var timeout=CancellationTokenSource.CreateLinkedTokenSource(cancellation);timeout.CancelAfter(TimeSpan.FromSeconds(5));
                var command=await reader.ReadLineAsync(timeout.Token).ConfigureAwait(false);
                var response=new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
                dispatch.BeginInvoke(()=>
                {
                    bool ok=true;string? error=null;
                    try
                    {
                        switch(command)
                        {
                            case "on":session.Start(null,settings.KeepLidAwake);break;
                            case "off":session.Stop();break;
                            case "quit":ok=StopForQuit();break;
                            case "status":ok=icon.Visible && !closing;break;
                            default:ok=false;error="Unknown command.";break;
                        }
                    }
                    catch(Exception ex){ok=false;error=ex.Message;}
                    if(!closing) Refresh();
                    response.TrySetResult(JsonSerializer.Serialize(new{ok,version=Program.Version,label=session.Active?"agents on":"agents off",active=session.Active,deadline=session.Deadline,visible=icon.Visible,error}));
                });
                var json=await response.Task.WaitAsync(TimeSpan.FromSeconds(15)).ConfigureAwait(false);
                await writer.WriteLineAsync(json).ConfigureAwait(false);
                using var result=JsonDocument.Parse(json);
                if(command=="quit" && result.RootElement.GetProperty("ok").GetBoolean())
                    dispatch.BeginInvoke(FinishQuit);
            }
            catch(OperationCanceledException) {if(cancellation.IsCancellationRequested) break;}
            catch(Exception) {if(cancellation.IsCancellationRequested) break;await Task.Delay(100,cancellation).ConfigureAwait(false);}
        }
    }
    internal static Icon CreateLight(bool active)
    {
        using var bitmap=new Bitmap(32,32);
        using(var graphics=Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode=SmoothingMode.AntiAlias;
            if(active)
            {
                using var glow=new SolidBrush(Color.FromArgb(50,70,255,110));graphics.FillEllipse(glow,1,1,30,30);
                using var inner=new SolidBrush(Color.FromArgb(80,70,255,110));graphics.FillEllipse(inner,4,4,24,24);
            }
            using var dot=new SolidBrush(active?Color.FromArgb(65,255,110):Color.FromArgb(160,160,160));graphics.FillEllipse(dot,7,7,18,18);
            using var outline=new Pen(Color.FromArgb(70,0,0,0));graphics.DrawEllipse(outline,7,7,18,18);
        }
        var native=bitmap.GetHicon();try{return (Icon)Icon.FromHandle(native).Clone();}finally{DestroyIcon(native);}
    }
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr icon);
    protected override void Dispose(bool disposing)
    {
        if(disposing && !disposed)
        {
            disposed=true;
            try {lease.Release();}catch {ExitCode=1;}
            shutdown.Cancel();tick.Dispose();icon.Visible=false;icon.Dispose();menu.Dispose();
            SystemEvents.PowerModeChanged-=PowerChanged;Application.ApplicationExit-=OnApplicationExit;
            dispatch.Dispose();onIcon.Dispose();offIcon.Dispose();shutdown.Dispose();
        }
        base.Dispose(disposing);
    }
}
