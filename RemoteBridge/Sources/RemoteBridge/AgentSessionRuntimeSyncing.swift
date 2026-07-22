protocol AgentSessionRuntimeSyncing: AnyObject {
    func sync(records: [AgentSessionRegistryRecord])

    // A single serialized reconciliation pass with an explicit fence between
    // retiring old producers and activating new/surviving ones. Conformers
    // whose producers publish sidebar side effects on their own queue MUST
    // guarantee, before `betweenRetirementAndActivation` is invoked, that
    // every old (departing/replaced) producer generation is either fully
    // drained (its legitimate final work already sent) or can no longer
    // publish (its generation is retired) — closing the gap that would
    // otherwise let a stale old-workspace sidebar message land after the
    // caller's departed-workspace cleanup. `betweenRetirementAndActivation`
    // runs the caller's cleanup (e.g. the departed-workspace prompt); only
    // after it returns may new/surviving producers be attached/activated, so
    // no new-workspace activation can ever precede that cleanup.
    // NON-escaping deliberately: monitor correctness depends on the callback
    // running synchronously exactly once, before this call returns (the
    // monitor mutates its local prepared-session list inside the closure,
    // then calls finishUpdate() immediately after reconcile() returns). An
    // escaping signature would let a conformer retain/defer it, breaking
    // that ordering (finish-before-prepare, lifecycle loss).
    func reconcile(records: [AgentSessionRegistryRecord], betweenRetirementAndActivation: () -> Void)
}

extension AgentSessionRuntimeSyncing {
    // Default for conformers with no independent sidebar-producing queue of
    // their own (e.g. test fakes): there is no retirement generation to
    // fence, so the callback can run immediately, before the ordinary sync.
    func reconcile(records: [AgentSessionRegistryRecord], betweenRetirementAndActivation: () -> Void) {
        betweenRetirementAndActivation()
        sync(records: records)
    }
}
