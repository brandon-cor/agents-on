using AgentsOn.Core;
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
    public static int Run()
    {
        try
        {
            // Exercise the real Windows assertion on this thread, without changing lid policy.
            try {WindowsAwakeLease.SetExecutionState(true);}finally{WindowsAwakeLease.SetExecutionState(false);}
            using var context=new TrayContext(new FakeLease(),testMode:true);
            int result=0;
            using var timer=new System.Windows.Forms.Timer{Interval=100};
            timer.Tick+=(_,_)=>
            {
                timer.Stop();
                try {context.CheckControls();}catch(Exception ex){Console.Error.WriteLine(ex);result=1;}
                Application.ExitThread();
            };
            timer.Start();Application.Run(context);
            Console.WriteLine("Native awake request, tray startup, left-click toggles, timer selection, and custom dialog verified.");
            return result;
        }
        catch(Exception ex){Console.Error.WriteLine(ex);return 1;}
    }
}
