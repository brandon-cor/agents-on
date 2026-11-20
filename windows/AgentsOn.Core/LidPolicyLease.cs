using System;
using System.Collections.Generic;

namespace AgentsOn.Core;

public readonly record struct LidPolicySnapshot(Guid Scheme, uint Ac, uint Dc);

public interface ILidPolicyPlatform
{
    Guid ActiveScheme { get; }
    uint ReadAc(Guid scheme);
    uint ReadDc(Guid scheme);
    void WriteAc(Guid scheme, uint value);
    void WriteDc(Guid scheme, uint value);
    void Apply(Guid scheme);
}

public interface ILidJournalStore
{
    LidPolicySnapshot? Load();
    void Save(LidPolicySnapshot snapshot);
    void Clear();
}

public sealed class LidPolicyLease(ILidPolicyPlatform platform, ILidJournalStore journal)
{
    public bool HasPending => journal.Load() is not null;

    public void Acquire()
    {
        // A previous interrupted session must be recovered before taking a new lease.
        Restore();

        var scheme = platform.ActiveScheme;
        var snapshot = new LidPolicySnapshot(scheme, platform.ReadAc(scheme), platform.ReadDc(scheme));
        if (snapshot.Ac > 3 || snapshot.Dc > 3)
            throw new InvalidOperationException("The lid-close power setting is not a recognized Windows action.");

        // Lid actions persist after process exit, so recovery must be durable first.
        journal.Save(snapshot);
        try
        {
            platform.WriteAc(scheme, 0);
            platform.WriteDc(scheme, 0);
            if (platform.ActiveScheme != scheme)
                throw new InvalidOperationException("The active power plan changed while enabling closed-lid mode.");
            platform.Apply(scheme);
        }
        catch (Exception acquireError)
        {
            try
            {
                Restore();
            }
            catch (Exception restoreError)
            {
                throw new AggregateException(
                    "Closed-lid mode could not start, and restoring the previous lid settings failed. Recovery is still pending.",
                    acquireError, restoreError);
            }

            throw new InvalidOperationException(
                "Closed-lid mode could not start. The previous lid settings were restored.", acquireError);
        }
    }

    public void Restore()
    {
        var pending = journal.Load();
        if (pending is not { } snapshot)
            return;

        if (snapshot.Ac > 3 || snapshot.Dc > 3)
            throw new InvalidOperationException("The saved lid-close settings are invalid; recovery remains pending.");

        var errors = new List<Exception>();
        Attempt("the plugged-in lid action", () =>
        {
            // A nonzero action was changed outside this lease; preserve that choice.
            if (platform.ReadAc(snapshot.Scheme) == 0 && snapshot.Ac != 0)
                platform.WriteAc(snapshot.Scheme, snapshot.Ac);
        });
        Attempt("the battery lid action", () =>
        {
            if (platform.ReadDc(snapshot.Scheme) == 0 && snapshot.Dc != 0)
                platform.WriteDc(snapshot.Scheme, snapshot.Dc);
        });
        Attempt("the active power plan", () =>
        {
            // Recover the saved plan without switching away from a user's new plan.
            if (platform.ActiveScheme == snapshot.Scheme)
                platform.Apply(snapshot.Scheme);
        });

        if (errors.Count > 0)
            throw new AggregateException("The previous lid settings could not be fully restored. Recovery is still pending.", errors);

        // Retain the snapshot after any read, write, or apply failure for a later retry.
        journal.Clear();

        void Attempt(string setting, Action action)
        {
            try
            {
                action();
            }
            catch (Exception error)
            {
                errors.Add(new InvalidOperationException($"Could not restore {setting}.", error));
            }
        }
    }

    public bool IsPolicyIntact()
    {
        var pending = journal.Load();
        return pending is { } snapshot
            && platform.ActiveScheme == snapshot.Scheme
            && platform.ReadAc(snapshot.Scheme) == 0
            && platform.ReadDc(snapshot.Scheme) == 0;
    }
}
