using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Reflection;
using AgentsOn.Core;

namespace AgentsOn.Windows;

internal static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        if(args.FirstOrDefault()=="--watch-parent") {try{return RecoveryWatchdog.Run(args);}catch{return 2;}}
        if(args.FirstOrDefault()=="--self-test-lock") return SmokeTests.CheckLock();
        ApplicationConfiguration.Initialize();
        Application.SetColorMode(SystemColorMode.System);
        if(args.Contains("--self-test")) return SmokeTests.Run();
        if(args.Length>0)
        {
            var command=args[0] switch {"--check-ui" or "--status"=>"status","--quit"=>"quit","--on"=>"on","--off"=>"off",_=>null};
            return command is null ? 2 : Send(command);
        }
        Mutex singleton;
        try {singleton=new Mutex(false,AppPaths.Mutex);}
        catch(UnauthorizedAccessException)
        {
            MessageBox.Show("Another Windows account is running Agents On or restoring its lid settings. Close that copy before starting this one.","Agents On",MessageBoxButtons.OK,MessageBoxIcon.Information);
            return 1;
        }
        using var ownedMutex=singleton;
        bool acquired;
        try { acquired=singleton.WaitOne(0); } catch(AbandonedMutexException){acquired=true;}
        if(!acquired)
        {
            var status=Send("status");
            if(status!=0)MessageBox.Show("Agents On is already running in another session, or is finishing recovery. Wait for recovery or close the other copy before starting this one.","Agents On",MessageBoxButtons.OK,MessageBoxIcon.Information);
            return status;
        }
        try
        {
            using var context=new TrayContext();
            Application.Run(context);
            return context.ExitCode;
        }
        catch(Exception ex)
        {
            MessageBox.Show(ex.Message,"Agents On could not start",MessageBoxButtons.OK,MessageBoxIcon.Error);
            return 1;
        }
        finally {singleton.ReleaseMutex();}
    }
    internal static int Send(string command)
    {
        try
        {
            using var pipe=new NamedPipeClientStream(".",AppPaths.Pipe,PipeDirection.InOut,PipeOptions.Asynchronous);
            pipe.Connect(5000);
            using var reader=new StreamReader(pipe,Encoding.UTF8,leaveOpen:true);
            using var writer=new StreamWriter(pipe,new UTF8Encoding(false),leaveOpen:true){AutoFlush=true};
            writer.WriteLine(command);
            var read=reader.ReadLineAsync();
            if(!read.Wait(TimeSpan.FromSeconds(20))) return 1;
            var result=read.Result ?? throw new IOException("No response from the tray app.");
            Console.WriteLine(result);
            using var doc=JsonDocument.Parse(result);
            if(!doc.RootElement.GetProperty("ok").GetBoolean()) return 1;
            if(command=="quit")
            {
                using var exited=new Mutex(false,AppPaths.Mutex);
                bool got;
                try {got=exited.WaitOne(TimeSpan.FromSeconds(10));} catch(AbandonedMutexException){got=true;}
                if(got) exited.ReleaseMutex();
                return got ? 0:1;
            }
            return 0;
        }
        catch(Exception ex)
        {
            if(command=="quit")
            {
                try
                {
                    using var stopped=new Mutex(false,AppPaths.Mutex);
                bool got;
                try {got=stopped.WaitOne(0);}catch(AbandonedMutexException){got=true;}
                if(got)
                {
                    try {new LidPolicyLease(new WindowsLidPolicy(),new JournalStore()).Restore();return 0;}
                    catch(Exception recovery){Console.Error.WriteLine(recovery.Message);return 1;}
                    finally{stopped.ReleaseMutex();}
                }
                }
                catch(UnauthorizedAccessException){Console.Error.WriteLine("Another Windows account is running Agents On or restoring lid settings.");return 1;}
            }
            Console.Error.WriteLine("Agents On did not respond: "+ex.Message);return 1;
        }
    }
    internal static string Version => typeof(Program).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "0.7.0";
}
