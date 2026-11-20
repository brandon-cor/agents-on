namespace AgentsOn.Core;

public interface IAwakeLease
{
    bool IsHeld { get; }
    void Acquire(bool keepLidAwake);
    void Release();
    bool IsPolicyIntact();
}

public sealed class SessionController(IAwakeLease lease, Func<DateTimeOffset>? clock = null)
{
    private readonly Func<DateTimeOffset> now = clock ?? (() => DateTimeOffset.UtcNow);
    private DateTimeOffset retryAt;
    public bool Active => lease.IsHeld;
    public DateTimeOffset? Deadline { get; private set; }
    public string? Error { get; private set; }
    public bool StopPending { get; private set; } = lease.IsHeld;

    public void Start(TimeSpan? duration, bool keepLidAwake)
    {
        if (duration is { } time && (time <= TimeSpan.Zero || time > TimeSpan.FromDays(365)))
            throw new ArgumentOutOfRangeException(nameof(duration), "Choose a duration greater than zero.");
        var end = duration is { } span ? now().Add(span) : (DateTimeOffset?)null;
        try
        {
            lease.Acquire(keepLidAwake);
            Deadline = end;
            StopPending = false;
            Error = null;
        }
        catch (Exception ex)
        {
            Deadline = null;
            Error = ex.Message;
            StopPending = lease.IsHeld;
            if (StopPending) retryAt = now().AddSeconds(5);
            throw;
        }
    }

    public void Stop()
    {
        Deadline = null;
        try
        {
            lease.Release();
            StopPending = false;
            Error = null;
        }
        catch (Exception ex)
        {
            Error = ex.Message;
            StopPending = true;
            retryAt = now().AddSeconds(5);
            throw;
        }
    }

    public void Tick()
    {
        if (StopPending && now() < retryAt) return;
        try
        {
            if (StopPending || (Active && (Deadline <= now() || !lease.IsPolicyIntact()))) Stop();
        }
        catch (Exception ex)
        {
            Error = ex.Message;
            StopPending = true;
            retryAt = now().AddSeconds(5);
        }
    }

    public string? Countdown => Deadline is { } end ? FormatCountdown(end - now()) + " remaining" : null;
    public static string FormatCountdown(TimeSpan remaining)
    {
        var seconds = (long)Math.Max(0, Math.Ceiling(remaining.TotalSeconds));
        var hours = seconds / 3600;
        return (hours > 0 ? $"{hours}h " : "") + $"{seconds % 3600 / 60}m {seconds % 60:00}s";
    }
    public static TimeSpan? ParseDuration(string hours, string minutes)
    {
        static decimal? Number(string value) => string.IsNullOrWhiteSpace(value) ? 0 :
            decimal.TryParse(value, System.Globalization.NumberStyles.Number, System.Globalization.CultureInfo.CurrentCulture, out var result) ? result : null;
        var h = Number(hours); var m = Number(minutes);
        if (h is null or < 0 || m is null or < 0) return null;
        try
        {
            var total = h.Value * 60 + m.Value;
            return total > 0 && total <= 525600 ? TimeSpan.FromMinutes((double)total) : null;
        }
        catch (OverflowException) { return null; }
    }
}
