using System;
using System.Collections.Generic;
using System.Linq;
using AgentsOn.Core;

namespace AgentsOn.Tests;

public static class LidTests
{
    public static void Run()
    {
        SavesBeforeChangingPowerPolicy();
        RestoresBothPowerSources();
        RollsBackFailedAcquisition();
        KeepsJournalWhenRollbackAlsoFails();
        RecoversAfterPartialRestoreFailure();
        RetriesFailedPolicyApplication();
        PreservesExternalEdits();
        RestoresOldPlanWithoutActivatingIt();
        RecoversInterruptedSessions();
        DoesNotWriteIfSavingFails();
        RejectsInvalidOriginalActions();
        RepeatedRestoreIsHarmless();
        Console.WriteLine("Lid leases: durable recovery, rollback, external edits, plan switches, and restart recovery verified.");
    }

    private static void SavesBeforeChangingPowerPolicy()
    {
        var fixture = new Fixture(1, 3);
        fixture.Journal.OnSave = snapshot =>
        {
            Check(fixture.Platform.Values(First) == (1u, 3u), "Saving must precede any power-setting change.");
            Check(snapshot == new LidPolicySnapshot(First, 1, 3), "Save the exact original plan and both actions.");
        };
        fixture.Platform.BeforeWrite = () => Check(
            fixture.Journal.Value == new LidPolicySnapshot(First, 1, 3),
            "The recovery snapshot must already be persisted before every write.");

        fixture.Lease.Acquire();

        Check(fixture.Platform.Values(First) == (0u, 0u), "Enable closed-lid mode on AC and battery.");
        Check(fixture.Platform.Applied.SequenceEqual([First]), "Apply the changed active plan.");
        Check(fixture.Lease.HasPending && fixture.Lease.IsPolicyIntact(), "The active lease must remain recoverable.");
    }

    private static void RestoresBothPowerSources()
    {
        var fixture = new Fixture(2, 3);
        fixture.Lease.Acquire();
        fixture.Lease.Restore();

        Check(fixture.Platform.Values(First) == (2u, 3u), "Restore distinct AC and battery actions exactly.");
        Check(!fixture.Lease.HasPending && !fixture.Lease.IsPolicyIntact(), "A recovered lease is no longer active.");
        Check(fixture.Journal.ClearCalls == 1, "Clear recovery only after successful restoration.");

        var alreadyDisabled = new Fixture(0, 0);
        alreadyDisabled.Lease.Acquire();
        alreadyDisabled.Lease.Restore();
        Check(alreadyDisabled.Platform.Values(First) == (0u, 0u), "Preserve originally disabled lid actions.");
        Check(!alreadyDisabled.Lease.HasPending, "Originally disabled actions must still allow recovery to finish.");
    }

    private static void RollsBackFailedAcquisition()
    {
        var fixture = new Fixture(1, 2);
        fixture.Platform.DcWriteFailuresRemaining = 1;

        Throws<InvalidOperationException>(() => fixture.Lease.Acquire());

        Check(fixture.Platform.Values(First) == (1u, 2u), "A failed battery write must roll back the earlier AC change.");
        Check(!fixture.Lease.HasPending, "Successful rollback must release the recovery journal.");
    }

    private static void KeepsJournalWhenRollbackAlsoFails()
    {
        var fixture = new Fixture(1, 2);
        fixture.Platform.DcWriteFailuresRemaining = 1;
        fixture.Platform.FailAcRestore = true;

        var error = Throws<AggregateException>(() => fixture.Lease.Acquire());

        Check(error.InnerExceptions.Count == 2, "Report both acquisition and rollback failures.");
        Check(fixture.Lease.HasPending, "Keep the original snapshot when rollback cannot finish.");
        Check(fixture.Journal.Value == new LidPolicySnapshot(First, 1, 2), "Do not overwrite the original recovery values.");
        fixture.Platform.FailAcRestore = false;
        fixture.Lease.Restore();
        Check(fixture.Platform.Values(First) == (1u, 2u) && !fixture.Lease.HasPending,
            "Recovery must succeed once the write failure is removed.");
    }

    private static void RecoversAfterPartialRestoreFailure()
    {
        var fixture = new Fixture(1, 2);
        fixture.Lease.Acquire();
        fixture.Platform.FailAcRestore = true;

        Throws<AggregateException>(() => fixture.Lease.Restore());

        Check(fixture.Platform.Values(First) == (0u, 2u), "Attempt battery restoration even when AC restoration fails.");
        Check(fixture.Lease.HasPending && fixture.Journal.ClearCalls == 0,
            "A partial restoration must retain its recovery snapshot.");
        fixture.Platform.FailAcRestore = false;
        fixture.Lease.Restore();
        Check(fixture.Platform.Values(First) == (1u, 2u), "Retry only the outstanding restoration without losing the battery value.");
        Check(!fixture.Lease.HasPending, "Clear the journal after the retry finishes.");
    }

    private static void RetriesFailedPolicyApplication()
    {
        var fixture = new Fixture(1, 3);
        fixture.Lease.Acquire();
        fixture.Platform.ApplyFailuresRemaining = 1;

        Throws<AggregateException>(() => fixture.Lease.Restore());

        Check(fixture.Platform.Values(First) == (1u, 3u), "Restore the values even if applying the plan fails.");
        Check(fixture.Lease.HasPending, "Writing values alone must not discard recovery before they are applied.");
        fixture.Lease.Restore();
        Check(!fixture.Lease.HasPending, "A later successful apply completes recovery.");
    }

    private static void PreservesExternalEdits()
    {
        var fixture = new Fixture(1, 2);
        fixture.Lease.Acquire();
        fixture.Platform.SetValues(First, 3, 1);
        Check(!fixture.Lease.IsPolicyIntact(), "Detect external lid-action edits.");
        fixture.Platform.Writes.Clear();
        fixture.Lease.Restore();

        Check(fixture.Platform.Values(First) == (3u, 1u), "Never replace externally chosen nonzero actions with old values.");
        Check(fixture.Platform.Writes.Count == 0, "External changes should require no restoration writes.");
        Check(!fixture.Lease.HasPending, "Preserving external choices completes recovery.");

        var mixed = new Fixture(1, 3);
        mixed.Lease.Acquire();
        mixed.Platform.SetValues(First, 2, 0);
        mixed.Lease.Restore();
        Check(mixed.Platform.Values(First) == (2u, 3u), "Preserve the edited power source while restoring the untouched source.");
    }

    private static void RestoresOldPlanWithoutActivatingIt()
    {
        var fixture = new Fixture(1, 2);
        fixture.Lease.Acquire();
        fixture.Platform.SetValues(Second, 3, 1);
        fixture.Platform.ActiveScheme = Second;
        fixture.Platform.Applied.Clear();
        Check(!fixture.Lease.IsPolicyIntact(), "A different active power plan invalidates the lease.");

        fixture.Lease.Restore();

        Check(fixture.Platform.Values(First) == (1u, 2u), "Restore settings in the leased plan after a plan switch.");
        Check(fixture.Platform.ActiveScheme == Second && fixture.Platform.Values(Second) == (3u, 1u),
            "Leave the user's newly active plan untouched.");
        Check(fixture.Platform.Applied.Count == 0, "Never reactivate the previous plan during recovery.");
        Check(!fixture.Lease.HasPending, "Restoration of an inactive plan can complete without activation.");
    }

    private static void RecoversInterruptedSessions()
    {
        var fixture = new Fixture(2, 1);
        fixture.Lease.Acquire();
        var restarted = new LidPolicyLease(fixture.Platform, fixture.Journal);

        Check(restarted.HasPending, "A fresh lease object must discover an interrupted session.");
        restarted.Restore();
        Check(fixture.Platform.Values(First) == (2u, 1u) && !restarted.HasPending,
            "Startup recovery must restore the prior session's values.");

        fixture.Lease.Acquire();
        var anotherRestart = new LidPolicyLease(fixture.Platform, fixture.Journal);
        anotherRestart.Acquire();
        Check(fixture.Journal.Value == new LidPolicySnapshot(First, 2, 1),
            "A new session must recover first rather than snapshotting the previous session's zero actions.");
        anotherRestart.Restore();
        Check(fixture.Platform.Values(First) == (2u, 1u), "Recovery before reacquisition preserves the actual original settings.");
    }

    private static void DoesNotWriteIfSavingFails()
    {
        var fixture = new Fixture(1, 3);
        fixture.Journal.FailSave = true;

        Throws<InvalidOperationException>(() => fixture.Lease.Acquire());

        Check(fixture.Platform.Writes.Count == 0 && fixture.Platform.Applied.Count == 0,
            "Journal-save failure must leave every power-setting operation untouched.");
        Check(fixture.Platform.Values(First) == (1u, 3u), "Saving failure must preserve original settings.");
    }

    private static void RejectsInvalidOriginalActions()
    {
        var fixture = new Fixture(4, 1);
        Throws<InvalidOperationException>(() => fixture.Lease.Acquire());
        Check(fixture.Platform.Writes.Count == 0 && fixture.Journal.SaveCalls == 0,
            "Unknown action values must not be saved or overwritten.");
    }

    private static void RepeatedRestoreIsHarmless()
    {
        var fixture = new Fixture(3, 2);
        fixture.Lease.Restore();
        Check(fixture.Platform.Writes.Count == 0 && fixture.Platform.Applied.Count == 0,
            "Restoring without a journal must not touch power policy.");
        fixture.Lease.Acquire();
        fixture.Lease.Restore();
        fixture.Platform.Writes.Clear();
        fixture.Platform.Applied.Clear();
        fixture.Lease.Restore();
        Check(fixture.Platform.Writes.Count == 0 && fixture.Platform.Applied.Count == 0,
            "Repeated restore after success must not write or apply settings again.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    private static T Throws<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T error) { return error; }
        throw new Exception($"Expected {typeof(T).Name}.");
    }

    private static readonly Guid First = Guid.Parse("11111111-1111-1111-1111-111111111111");
    private static readonly Guid Second = Guid.Parse("22222222-2222-2222-2222-222222222222");

    private sealed class Fixture
    {
        public FakeJournal Journal { get; } = new();
        public FakePlatform Platform { get; }
        public LidPolicyLease Lease { get; }
        public Fixture(uint ac, uint dc)
        {
            Platform = new FakePlatform(Journal);
            Platform.SetValues(First, ac, dc);
            Lease = new LidPolicyLease(Platform, Journal);
        }
    }

    private sealed class FakeJournal : ILidJournalStore
    {
        public LidPolicySnapshot? Value;
        public bool FailSave;
        public int SaveCalls;
        public int ClearCalls;
        public Action<LidPolicySnapshot>? OnSave;
        public LidPolicySnapshot? Load() => Value;
        public void Save(LidPolicySnapshot snapshot)
        {
            SaveCalls++;
            if (FailSave) throw new InvalidOperationException("Simulated durable-storage failure.");
            OnSave?.Invoke(snapshot);
            Value = snapshot;
        }
        public void Clear() { ClearCalls++; Value = null; }
    }

    private sealed class FakePlatform(FakeJournal journal) : ILidPolicyPlatform
    {
        private readonly Dictionary<Guid, (uint Ac, uint Dc)> plans = new();
        public Guid ActiveScheme { get; set; } = First;
        public readonly List<(Guid Scheme, bool Ac, uint Value)> Writes = new();
        public readonly List<Guid> Applied = new();
        public int DcWriteFailuresRemaining;
        public int ApplyFailuresRemaining;
        public bool FailAcRestore;
        public Action? BeforeWrite;
        public (uint Ac, uint Dc) Values(Guid scheme) => plans[scheme];
        public void SetValues(Guid scheme, uint ac, uint dc) => plans[scheme] = (ac, dc);
        public uint ReadAc(Guid scheme) => plans[scheme].Ac;
        public uint ReadDc(Guid scheme) => plans[scheme].Dc;
        public void WriteAc(Guid scheme, uint value)
        {
            Check(journal.Value is not null, "An AC write happened without a durable recovery snapshot.");
            BeforeWrite?.Invoke();
            if (FailAcRestore && value != 0) throw new InvalidOperationException("Simulated AC restoration failure.");
            Writes.Add((scheme, true, value));
            plans[scheme] = (value, plans[scheme].Dc);
        }
        public void WriteDc(Guid scheme, uint value)
        {
            Check(journal.Value is not null, "A battery write happened without a durable recovery snapshot.");
            BeforeWrite?.Invoke();
            if (DcWriteFailuresRemaining > 0)
            {
                DcWriteFailuresRemaining--;
                throw new InvalidOperationException("Simulated battery-setting failure.");
            }
            Writes.Add((scheme, false, value));
            plans[scheme] = (plans[scheme].Ac, value);
        }
        public void Apply(Guid scheme)
        {
            if (ApplyFailuresRemaining > 0)
            {
                ApplyFailuresRemaining--;
                throw new InvalidOperationException("Simulated power-plan apply failure.");
            }
            Applied.Add(scheme);
            ActiveScheme = scheme;
        }
    }
}
