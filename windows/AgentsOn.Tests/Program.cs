using AgentsOn.Core;
using AgentsOn.Tests;

static void Check(bool value,string message){if(!value)throw new Exception(message);}
var time=new DateTimeOffset(2026,11,20,12,0,0,TimeSpan.Zero);
var lease=new FakeLease();
var session=new SessionController(lease,()=>time);
Check(!session.Active,"starts off");
session.Start(null,true);Check(session.Active && session.Deadline==null && lease.Lid,"indefinite session");
session.Stop();Check(!session.Active,"stop releases");
session.Start(TimeSpan.FromMinutes(30),true);
Check(session.Countdown=="30m 00s remaining","initial countdown");
time=time.AddSeconds(1);Check(session.Countdown=="29m 59s remaining","seconds countdown");
session.Start(TimeSpan.FromHours(1.5),false);Check(session.Countdown=="1h 30m 00s remaining" && !lease.Lid,"replacement timer");
time=time.AddHours(2);session.Tick();Check(!session.Active && session.Deadline==null,"timer expiry");
session.Start(TimeSpan.FromSeconds(1),true);lease.FailRelease=true;time=time.AddSeconds(2);session.Tick();
Check(session.Active && session.StopPending && session.Error!=null,"failed expiry retains pending status");
var attempts=lease.ReleaseAttempts;session.Tick();Check(lease.ReleaseAttempts==attempts,"retry backs off");
lease.FailRelease=false;time=time.AddSeconds(5);session.Tick();Check(!session.Active && !session.StopPending,"expiry retries");
session.Start(null,true);lease.Intact=false;session.Tick();Check(!session.Active,"external power policy changes stop the session");
Check(SessionController.ParseDuration("1","30")==TimeSpan.FromMinutes(90),"custom hours and minutes");
Check(SessionController.ParseDuration("","30")==TimeSpan.FromMinutes(30),"empty fields mean zero");
Check(SessionController.ParseDuration("0","0")==null && SessionController.ParseDuration("-1","30")==null,"invalid durations");
Check(SessionController.ParseDuration("6","0")==TimeSpan.FromHours(6),"no five-hour limit");
Check(SessionController.ParseDuration("9999999999999999999999999999","0")==null,"unreasonable input");
lease.Intact=true;session.Start(TimeSpan.FromMinutes(30),true);lease.FailAcquire=true;
try {session.Start(TimeSpan.FromMinutes(60),true);}catch(IOException) { }
Check(!session.Active && session.Deadline==null,"failed replacement clears the old countdown");
var recovering=new FakeLease();recovering.Acquire(true);
var recoverySession=new SessionController(recovering,()=>time);
Check(recoverySession.StopPending,"existing recovery is pending at startup");
recoverySession.Tick();Check(!recoverySession.Active && !recoverySession.StopPending,"startup recovery retries");
LidTests.Run();
Console.WriteLine("Windows session, timer, retry, input, and lid-policy recovery tests passed.");
sealed class FakeLease:IAwakeLease
{
    public bool IsHeld{get;private set;}
    public bool Lid,FailRelease,FailAcquire,Intact=true;
    public int ReleaseAttempts;
    public void Acquire(bool lid){if(FailAcquire){IsHeld=false;throw new IOException("simulated start failure");}IsHeld=true;Lid=lid;}
    public void Release(){ReleaseAttempts++;if(FailRelease)throw new IOException("simulated denial");IsHeld=false;}
    public bool IsPolicyIntact()=>Intact;
}
