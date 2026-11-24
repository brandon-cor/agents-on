using AgentsOn.Core;
using System.Diagnostics;
namespace AgentsOn.Windows;
internal static class SmokeTests
{
    private sealed class FakeLease:IAwakeLease
    {
        public bool IsHeld{get;private set;}
        public void Acquire(bool lid)=>IsHeld=true;
        public void Release()=>IsHeld=false;
        public bool IsPolicyIntact()=>true;
    }
    public static int CheckLock()
    {
        try
        {
            using var mutex=new Mutex(false,AppPaths.Mutex);
            bool acquired;
            try {acquired=mutex.WaitOne(0);}catch(AbandonedMutexException){acquired=true;}
            if(acquired){mutex.ReleaseMutex();return 1;}
            return 0;
        }
        catch(UnauthorizedAccessException){return 0;}
    }
    public static int Run()
    {
        try
        {
            // Exercise the real Windows assertion on this thread, without changing lid policy.
            try {WindowsAwakeLease.SetExecutionState(true);}finally{WindowsAwakeLease.SetExecutionState(false);}
            using(var owner=new Mutex(false,AppPaths.Mutex))
            {
                bool acquired;
                try {acquired=owner.WaitOne(0);}catch(AbandonedMutexException){acquired=true;}
                if(!acquired)throw new Exception("Close the running tray app before testing.");
                try
                {
                    using var probe=Process.Start(new ProcessStartInfo(Environment.ProcessPath!,"--self-test-lock"){UseShellExecute=false,CreateNoWindow=true})!;
                    if(!probe.WaitForExit(15000) || probe.ExitCode!=0)throw new Exception("Power ownership was not exclusive across processes.");
                }
                finally{owner.ReleaseMutex();}
            }
            using var context=new TrayContext(new FakeLease(),testMode:true);
            int result=0;
            using var timer=new System.Windows.Forms.Timer{Interval=100};
            timer.Tick+=(_,_)=>
            {
                timer.Stop();
                try {context.CheckControls();CheckDurationDialog();}catch(Exception ex){Console.Error.WriteLine(ex);result=1;}
                Application.ExitThread();
            };
            timer.Start();Application.Run(context);
            Console.WriteLine("Native awake request, tray startup, left-click toggles, timer selection, and custom dialog verified.");
            return result;
        }
        catch(Exception ex){Console.Error.WriteLine(ex);return 1;}
    }

    private static void CheckDurationDialog()
    {
        using(var form=new DurationForm(ModernTheme.For(false)))
        {
            form.Show();Application.DoEvents();
            if(form.HoursInput.Text!="0" || form.MinutesInput.Text!="0")throw new Exception("Duration fields were not zero-filled.");
            if(form.SubmitDuration() || form.DialogResult==DialogResult.OK || form.ValidationMessage.Length==0)
                throw new Exception("A zero duration was accepted or did not show validation.");
            form.HoursInput.Text="1";form.MinutesInput.Text="30";
            if(form.ValidationMessage.Length!=0)throw new Exception("Validation did not clear after editing.");
            if(!form.ProcessDialogKeyForTest(Keys.Enter) || form.DialogResult!=DialogResult.OK || form.Duration!=TimeSpan.FromMinutes(90))
                throw new Exception("Enter did not start the hours/minutes duration.");
        }
        using(var form=new DurationForm(ModernTheme.For(true)))
        {
            form.Show();Application.DoEvents();
            form.HoursInput.Text="";
            form.SelectNextControl(form.HoursInput,true,true,true,false);Application.DoEvents();
            if(!form.MinutesInput.Focused || form.HoursInput.Text!="0")throw new Exception("Tab navigation or empty-field reset failed.");
            if(!form.ProcessDialogKeyForTest(Keys.Escape) || form.DialogResult!=DialogResult.Cancel)
                throw new Exception("Escape did not cancel the duration dialog.");
        }
        Console.WriteLine("Light/dark menus, zero validation, hours/minutes, Enter, Escape, and Tab verified.");
    }
}
