using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using AgentsOn.Core;

namespace AgentsOn.Windows;

internal static class AppPaths
{
    public static readonly string Data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Agents On");
    public static readonly string UserId = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(WindowsIdentity.GetCurrent().User!.Value)))[..24];
    public static readonly string Pipe = "AgentsOn-" + UserId;
    public static readonly string Mutex = @"Global\AgentsOn-" + UserId;
}

internal sealed class JournalStore : ILidJournalStore
{
    private readonly string path = Path.Combine(AppPaths.Data, "lid-recovery.json");
    public bool Exists => File.Exists(path);
    public LidPolicySnapshot? Load()
    {
        if (!File.Exists(path)) return null;
        try { return JsonSerializer.Deserialize<LidPolicySnapshot?>(File.ReadAllText(path)) ?? throw new InvalidDataException("Empty recovery record."); }
        catch (Exception ex) { throw new InvalidDataException("The saved lid settings could not be read. Keep Agents On open and check lid-recovery.json in its app-data folder.", ex); }
    }
    public void Save(LidPolicySnapshot value)
    {
        Directory.CreateDirectory(AppPaths.Data);
        var temp = path + ".tmp";
        using (var file = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None))
        {
            JsonSerializer.Serialize(file, value);
            file.Flush(flushToDisk: true);
        }
        File.Move(temp, path, overwrite: true);
    }
    public void Clear() => File.Delete(path);
}

internal sealed class WindowsLidPolicy : ILidPolicyPlatform
{
    private static readonly Guid Buttons = new("4f971e89-eebd-4455-a8de-9e59040e7347");
    private static readonly Guid Lid = new("5ca83367-6e45-459f-a27b-476b1d01c936");
    public Guid ActiveScheme
    {
        get
        {
            Check(PowerGetActiveScheme(IntPtr.Zero, out var pointer));
            try { return Marshal.PtrToStructure<Guid>(pointer); }
            finally { LocalFree(pointer); }
        }
    }
    public uint ReadAc(Guid scheme) { var group=Buttons; var setting=Lid; Check(PowerReadACValueIndex(IntPtr.Zero, ref scheme, ref group, ref setting, out var value)); return value; }
    public uint ReadDc(Guid scheme) { var group=Buttons; var setting=Lid; Check(PowerReadDCValueIndex(IntPtr.Zero, ref scheme, ref group, ref setting, out var value)); return value; }
    public void WriteAc(Guid scheme,uint value) {var group=Buttons;var setting=Lid;Check(PowerWriteACValueIndex(IntPtr.Zero,ref scheme,ref group,ref setting,value));}
    public void WriteDc(Guid scheme,uint value) {var group=Buttons;var setting=Lid;Check(PowerWriteDCValueIndex(IntPtr.Zero,ref scheme,ref group,ref setting,value));}
    public void Apply(Guid scheme) => Check(PowerSetActiveScheme(IntPtr.Zero, ref scheme));
    private static void Check(uint error) { if(error!=0) throw new Win32Exception((int)error, "Windows could not change or restore the lid setting. Your device or organization may restrict power settings."); }
    [DllImport("powrprof.dll")] private static extern uint PowerGetActiveScheme(IntPtr key,out IntPtr scheme);
    [DllImport("powrprof.dll")] private static extern uint PowerReadACValueIndex(IntPtr key,ref Guid scheme,ref Guid subgroup,ref Guid setting,out uint value);
    [DllImport("powrprof.dll")] private static extern uint PowerReadDCValueIndex(IntPtr key,ref Guid scheme,ref Guid subgroup,ref Guid setting,out uint value);
    [DllImport("powrprof.dll")] private static extern uint PowerWriteACValueIndex(IntPtr key,ref Guid scheme,ref Guid subgroup,ref Guid setting,uint value);
    [DllImport("powrprof.dll")] private static extern uint PowerWriteDCValueIndex(IntPtr key,ref Guid scheme,ref Guid subgroup,ref Guid setting,uint value);
    [DllImport("powrprof.dll")] private static extern uint PowerSetActiveScheme(IntPtr key,ref Guid scheme);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
}

internal sealed class WindowsAwakeLease : IAwakeLease
{
    private readonly JournalStore journal = new();
    private readonly LidPolicyLease lid;
    private bool recoveryPending;
    public WindowsAwakeLease() {lid=new(new WindowsLidPolicy(),journal);}
    private bool executionHeld;
    private bool withLid;
    private Process? watchdog;
    public bool IsHeld => executionHeld || recoveryPending || journal.Exists;
    public void Recover() {recoveryPending=true;lid.Restore();recoveryPending=false;}
    public void Acquire(bool keepLidAwake)
    {
        if(executionHeld && withLid==keepLidAwake && IsPolicyIntact()) return;
        Release();
        try
        {
            if(keepLidAwake)
            {
                EnsureWatchdog();
                lid.Acquire();
            }
            SetExecutionState(true);
            executionHeld=true;
            withLid=keepLidAwake;
        }
        catch(Exception startError)
        {
            try { Release(); }
            catch(Exception recoveryError) {throw new AggregateException("Keep-awake could not start and restoring the lid settings is still pending.",startError,recoveryError);}
            throw;
        }
    }
    public void Release()
    {
        var errors=new List<Exception>();
        if(executionHeld)
        {
            try { SetExecutionState(false); executionHeld=false; }
            catch(Exception ex){errors.Add(ex);}
        }
        try {lid.Restore();recoveryPending=false;} catch(Exception ex){recoveryPending=true;errors.Add(ex);}
        if(errors.Count>0) throw new AggregateException("Normal sleep settings could not be fully restored. Retrying every five seconds.",errors);
        withLid=false;
    }
    public bool IsPolicyIntact() => !withLid || (watchdog is { HasExited: false } && lid.IsPolicyIntact());
    private void EnsureWatchdog()
    {
        if(watchdog is { HasExited: false }) return;
        watchdog?.Dispose();
        var name=@"Local\AgentsOn.Ready."+Guid.NewGuid().ToString("N");
        using var ready=new EventWaitHandle(false,EventResetMode.ManualReset,name);
        using var parent=Process.GetCurrentProcess();
        var info=new ProcessStartInfo(Environment.ProcessPath!) {UseShellExecute=false,CreateNoWindow=true};
        info.ArgumentList.Add("--watch-parent");info.ArgumentList.Add(parent.Id.ToString());
        info.ArgumentList.Add(parent.StartTime.ToUniversalTime().Ticks.ToString());info.ArgumentList.Add(name);
        var child=Process.Start(info) ?? throw new IOException("Could not start lid-setting recovery.");
        if(!ready.WaitOne(TimeSpan.FromSeconds(8)) || child.HasExited)
            throw new IOException("Lid-setting recovery did not start, so the lid settings were left unchanged.");
        watchdog=child;
    }
    internal static void SetExecutionState(bool enabled)
    {
        const uint continuous=0x80000000,system=0x1,display=0x2;
        if(SetThreadExecutionState(continuous | (enabled ? system|display : 0))==0)
            throw new Win32Exception("Windows did not accept the keep-awake request.");
    }
    [DllImport("kernel32.dll",SetLastError=true)] private static extern uint SetThreadExecutionState(uint flags);
}

internal static class RecoveryWatchdog
{
    public static int Run(string[] args)
    {
        if(args.Length!=4 || !int.TryParse(args[1],out var pid) || !long.TryParse(args[2],out var ticks) ||
           !args[3].StartsWith(@"Local\AgentsOn.Ready.",StringComparison.Ordinal)) return 2;
        // The child never owns an awake request; it only restores a saved lid policy after its parent exits.
        try
        {
            using var parent=Process.GetProcessById(pid);
            if(parent.StartTime.ToUniversalTime().Ticks!=ticks || !string.Equals(parent.MainModule?.FileName,Environment.ProcessPath,StringComparison.OrdinalIgnoreCase)) return 2;
            using var ready=EventWaitHandle.OpenExisting(args[3]);
            ready.Set();
            parent.WaitForExit();
        }
        catch(ArgumentException) { /* parent exited before the watchdog opened it */ }
        catch(Exception) { return 2; }
        var policy=new LidPolicyLease(new WindowsLidPolicy(),new JournalStore());
        // Serialize with a newly launched copy so it cannot overwrite a pending recovery record.
        using var instance=new Mutex(false,AppPaths.Mutex);
while(true)
        {
            try {instance.WaitOne();}catch(AbandonedMutexException) { }
            try
            {
                policy.Restore();
                try {File.Delete(Path.Combine(AppPaths.Data,"recovery-error.txt"));}catch { }
                return 0;
            }
            catch(Exception ex)
            {
                try {Directory.CreateDirectory(AppPaths.Data);File.WriteAllText(Path.Combine(AppPaths.Data,"recovery-error.txt"),ex.ToString());}catch { }
            }
            finally {instance.ReleaseMutex();}
            // A relaunched tray app must be able to acquire the mutex and show recovery errors.
            Thread.Sleep(5000);
        }
    }
}
