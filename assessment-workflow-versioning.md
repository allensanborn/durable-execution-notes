# Assessment: Dapr Workflow Versioning as Shipped, and Its Residual Gaps

**Status:** Draft — assessment, not a proposal
**Target repo:** n/a (input to `dapr/proposals` and `dapr/docs` follow-ups)
**Affects:** `dapr/dapr`, `dapr/durabletask-go`, `dapr/durabletask-protobuf`, `dapr/cli`, SDKs, docs
**Author:** Allen Sanborn
**Date:** 2026-09

---

## 0. The correction, up front

**Dapr Workflow ships both of the mechanisms Temporal has. Any analysis saying otherwise — including
an earlier draft of mine — is wrong.**

- **Patching:** `ctx.IsPatched("name")`, history-tracked, branch on whether a change was present when
  the instance started.
- **Named workflow versions:** register multiple implementations under one canonical name with an
  `isLatest` marker; an instance records which version ran it and replays against that version forever.

This is not experimental and not behind a feature gate. Primary sources:

- **Accepted proposal:** [`20251028-BRS-workflow-versioning.md`](https://github.com/dapr/proposals/blob/main/20251028-BRS-workflow-versioning.md),
  "Workflow Patching and Versioning" (Whit Waldo), merged into `dapr/proposals` main. It unifies
  [#82](https://github.com/dapr/proposals/pull/82) (named versions) and
  [#92](https://github.com/dapr/proposals/pull/92) (patching), and states plainly: *"Both are common
  approaches to the problem — Temporal implements both of them."*
- **Tracking issue:** [dapr/dapr#9162](https://github.com/dapr/dapr/issues/9162) — **closed**,
  milestone v1.17.
- **Docs page:** https://docs.dapr.io/developing-applications/building-blocks/workflow/workflow-versioning/
- **Release:** the v1.17.0 release notes announce it, with SDK support in Go, Python, .NET and Java.

### Two corrections to the correction

I verified the brief I was given against the source rather than taking it on trust, and two details need
adjusting. Neither changes the conclusion.

**It shipped in 1.17, not 1.18.** Checked by file presence at tags:

| file | v1.17.0 | v1.18.0 |
| --- | --- | --- |
| `pkg/actors/targets/workflow/orchestrator/versioning.go` | present | present |
| `pkg/runtime/wfengine/state/version.go` | **absent** | present |

So patching, named versions and the stall machinery landed in **1.17.0**; surfacing the version *name*
on workflow metadata landed in **1.18.0**. Saying "1.18" understates how long this has been available
and mis-dates the docs page, which exists for v1.17 as well.

**Two Python line numbers in the brief are off by 53.** At tag `v1.18.3`,
`ext/dapr-ext-workflow/dapr/ext/workflow/workflow_runtime.py` has `register_versioned_workflow` at
**line 200** and `versioned_workflow` at **line 340** — not 253 and 393. Those cited numbers appear to
come from `main`, where the file has since moved. The symbols and the substance are correct.

Confirmed exactly as briefed: `dapr_workflow_context.py:169` is `def is_patched`, and `call_activity`
is at line 64 of the same file in the same release — **105 lines apart**. That detail matters and §5
returns to it.

---

## 1. Abstract

The execution half of workflow versioning is done, and done well. An instance pins the version that
started it and replays against that version; a patch branches deterministically on whether it was
present at start; a version mismatch **stalls** rather than fails, preserving state, and self-heals once
a capable replica picks up the turn. The design is sound and the implementation matches it.

What is thin is everything *around* execution — the lifecycle. Verified against `dapr/dapr` at v1.18.3
and `main`:

1. **A stalled workflow reports `runtimeStatus: "UNKNOWN"`** through the Dapr workflow API, because
   `statusMap` stops at 7 and `ORCHESTRATION_STATUS_STALLED` is 8.
2. **The version dimension is invisible in aggregate.** No `version` label on any of the 23 workflow
   metrics; no version on `GetWorkflowResponse`; no `ListWorkflows` RPC; no version column or filter in
   `dapr workflow list`. No metric fires on stall at all.
3. **Patches can never be retired.** Removing a patch identifier is a permanent stall. There is no
   `DeprecatePatch` equivalent.
4. **Nothing detects an incompatible change before replay**, and the sidecar structurally cannot — it
   has no manifest of what its app can run.

The load-bearing consequence: the docs tell operators that older named versions *"should not be deleted
at all unless you've independently confirmed that there are no outstanding (in-flight or dormant)
workflow instances that are running against that version."* **There is no supported way to confirm
that.** The correct operator behavior today is therefore "never delete anything," which compounds with
every deploy.

Compared against Temporal, the shipped feature is roughly at parity on **patching minus
`DeprecatePatch`**, and has no analogue of Temporal's **Worker Versioning v2** operational layer —
drainage status, ramping, per-version census. §4 argues that most of that absence is correct for Dapr's
architecture and that one part of it is not.

---

## 2. What they actually built, mechanically

### 2.1 The wire format

In `dapr/durabletask-protobuf`:

```proto
// protos/orchestration.proto:37-42
message WorkflowVersion {
    repeated string patches = 1;
    // The name of the executed workflow
    optional string name = 2;
}

// protos/orchestration.proto:13-17
enum StalledReason {
    PATCH_MISMATCH = 0;
    VERSION_NOT_AVAILABLE = 1;
    PAYLOAD_SIZE_EXCEEDED = 2;
}

// protos/history_events.proto:198-200
message WorkflowStartedEvent {
    optional WorkflowVersion version = 1;
}
```

`WorkflowStartedEvent` is Dapr's rename of DTFx's `OrchestratorStartedEvent`, written **once per
orchestrator turn**. `ORCHESTRATION_STATUS_STALLED = 8` was added to `OrchestrationStatus`, and
`WorkflowVersionNotAvailableAction` (`orchestrator_actions.proto:116`) to the `WorkflowAction` oneof.

Note the divergence from the accepted proposal, which specified:

```protos
message PatchInformation {
    map[string]bool patchEvaluations = 1;
}
```

recording *how each patch evaluated*, explicitly "for replay-mismatch detection purposes." What shipped
is `repeated string patches` — only patches that evaluated **true** are recorded. §4.3 shows why that
choice constrains what a `DeprecatePatch` could do.

### 2.2 Tracing `IsPatched` to where the decision is recorded

Three hops: evaluate, accumulate, persist.

**Hop 1 — evaluate.** `durabletask-go/task/orchestrator.go:731-758`:

```go
func (ctx *WorkflowContext) IsPatched(patchName string) bool {
	isPatched := ctx.isPatched(patchName)
	if isPatched {
		ctx.encounteredPatches = append(ctx.encounteredPatches, patchName)
	}
	return isPatched
}

func (ctx *WorkflowContext) isPatched(patchName string) bool {
	if patched, exists := ctx.appliedPatches[patchName]; exists { return patched }
	if ctx.historyPatches[patchName] { ctx.appliedPatches[patchName] = true; return true }
	totalEvents := len(ctx.oldEvents) + len(ctx.newEvents)
	if ctx.historyIndex < totalEvents {
		// We're not at the end of the history stream, we assume the previous used the unpatched version
		ctx.appliedPatches[patchName] = false
		return false
	}
	// We're at the end of the history stream, we can run the patched version and save the decision for next rerun
	ctx.appliedPatches[patchName] = true
	return true
}
```

**This is the single most interesting design choice in the implementation, and it differs materially
from Temporal.** Temporal writes a `MarkerRecorded` event at the point of evaluation, interleaved in
command order with activities and timers — marker name `"Version"` in Go/Java
(`sdk-go/internal/internal_command_state_machine.go:230-240`), `"core_patch"` in the sdk-core family
(`sdk-core/crates/protos/src/protos/constants.rs:4`). The decision is a positioned event.

Dapr records no per-patch event. It infers "am I replaying?" **positionally** — `historyIndex <
totalEvents` means there is more recorded history ahead, so this code path was already executed and the
patch cannot have been taken; at the tip of history, we are executing new code and it can. The decision
is then cached in `appliedPatches` for the rest of the turn.

This is cheaper and simpler, and it is sound for the straight-line case. It costs one thing: a patch
that evaluates **false** leaves no trace anywhere, so "evaluated false" and "never reached on this
path" are indistinguishable in history.

**Hop 2 — accumulate onto the response.** `durabletask-go/task/executor.go:182-192`:

```go
	if len(workflowCtx.encounteredPatches) > 0 {
		if response.Version == nil { response.Version = new(protos.WorkflowVersion) }
		response.Version.Patches = workflowCtx.encounteredPatches
	}
	if workflowCtx.VersionName != nil {
		if response.Version == nil { response.Version = new(protos.WorkflowVersion) }
		response.Version.Name = workflowCtx.VersionName
	}
```

**Hop 3 — persist onto the turn's `WorkflowStarted` event**, and read back on the next replay
(`task/orchestrator.go:314-323`):

```go
	if os := e.GetWorkflowStarted(); os != nil {
		// WorkflowStarted is only used to update the current workflow time and history patches
		ctx.CurrentTimeUtc = e.Timestamp.AsTime()
		if version := os.GetVersion(); version != nil {
			for _, p := range version.GetPatches() {
				ctx.historyPatches[p] = true
			}
			if version.Name != nil {
				ctx.VersionName = ptr.Of(version.GetName())
			}
		}
	}
```

So the recorded artifact is **a per-turn list of newly-true patch names**, and replay reconstitutes the
true-set by unioning those lists across all `WorkflowStarted` events.

**Enforcement is on the runtime side**, in `dapr/dapr` —
`pkg/actors/targets/workflow/orchestrator/versioning.go`, the whole of which is 168 lines:

```go
func (o *orchestrator) hasPatchMismatch(rs *backend.WorkflowRuntimeState) (bool, string) {
	historyPatches := collectAllPatches(rs.OldEvents)
	currentPatches := getLastPatches(rs.NewEvents)
	if len(historyPatches) == 0 { return false, "" }
	// History patches must be an exact prefix of current patches
	if len(currentPatches) >= len(historyPatches) &&
		slices.Equal(historyPatches, currentPatches[:len(historyPatches)]) {
		return false, ""
	}
	return true, fmt.Sprintf("Patch mismatch. History patches: [%s], current patches: [%s]. ", ...)
}
```

**Exact-prefix matching is what makes patches permanent.** Remove `IsPatched("p1")` and
`historyPatches = ["p1"]` while `currentPatches = []`; the length check fails; the instance stalls,
forever. The docs list the three causes: *"Removing (or renaming) a patch identifier"*, *"Changing the
order of patches"*, *"Reusing a previously deployed patch identifier."*

### 2.3 The named-version routing path

Routing is **entirely app-local and lazy**. There is no runtime component to it at all.

`durabletask-go/task/registry.go:122-158`:

```go
func (r *TaskRegistry) ResolveWorkflow(name string, pinnedVersion *string) (Workflow, *string, error) {
	// Exact non-versioned match.
	if w, ok := r.workflows[name]; ok { return w, nil, nil }
	// Versioned match.
	if versions, ok := r.versionedWorkflows[name]; ok {
		var versionToUse string
		if pinnedVersion != nil {
			versionToUse = *pinnedVersion
		} else if latest, ok := r.latestVersionedWorkflows[name]; ok {
			versionToUse = latest
		} else {
			return nil, nil, fmt.Errorf("versioned workflow '%s' does not have a latest version registered", name)
		}
		if w, ok := versions[versionToUse]; ok { return w, &versionToUse, nil }
		return nil, nil, api.NewUnsupportedVersionError()
	} else if pinnedVersion != nil {
		return nil, nil, api.NewUnsupportedVersionError()
	}
	// Wildcard fallback.
	if w, ok := r.workflows["*"]; ok { return w, nil, nil }
	return nil, nil, fmt.Errorf("workflow named '%s' is not registered", name)
}
```

Called from `getWorkflow` → `onExecutionStarted` (`task/orchestrator.go:759-772`). The flow is:

1. First turn: `pinnedVersion` is nil → resolve `latest` → set `ctx.VersionName`.
2. Report it back on `WorkflowResponse.version`; durabletask-go stamps it onto `WorkflowStarted`.
3. Every later turn: read the name back out of history, pass it as `pinnedVersion`, resolve exactly.

Two structural notes. **`"*"` is a wildcard escape hatch** — an app registering it swallows any unknown
name and would defeat any validation built on top of the registry. And **the actor type carries the
app-id and nothing else** (`pkg/actors/targets/workflow/common/common.go`):

```go
func (a *ActorTypeBuilder) Workflow(appID string) string {
	return "dapr.internal." + a.ns + "." + appID + ".workflow"
}
```

No version, no revision, no pod identity. A new deployment silently inherits every in-flight instance of
the old one. This is the fact from which most of §4 follows.

### 2.4 `WorkflowVersionNotAvailableAction`: what happens when no worker can serve an instance

The path, end to end:

1. `ResolveWorkflow` returns `api.NewUnsupportedVersionError()` because the pinned version is not in
   this app's registry.
2. `task/orchestrator.go:1138-1147` turns it into an action, not an error:

```go
func (ctx *WorkflowContext) setVersionNotRegistered() error {
	sequenceNumber := ctx.getNextSequenceNumber()
	ctx.pendingActions[sequenceNumber] = &protos.WorkflowAction{
		Id: sequenceNumber,
		WorkflowActionType: &protos.WorkflowAction_WorkflowVersionNotAvailable{
			WorkflowVersionNotAvailable: &protos.WorkflowVersionNotAvailableAction{},
		},
	}
	return nil
}
```

3. The applier converts it to a stall message (`backend/runtimestate/applier.go:454-476`), reading the
   version name back out of history for the description: `"Version not available: %s"`, reason
   `StalledReason_VERSION_NOT_AVAILABLE`.
4. `dapr/dapr`'s `stallWorkflow` **discards the turn's output** and parks the actor indefinitely, holding
   its turn lock:

```go
	rs.CompletedEvent = nil
	rs.CompletedTime = nil
	hasFilteredNewEvents := len(rs.NewEvents) > 0
	rs.NewEvents = []*protos.HistoryEvent{}
	… appends ExecutionStalled to history, deduped on identical description …
	log.Infof("Workflow actor '%s': workflow is stalled; holding execution until context is canceled", o.actorID)
	releaseCh, unlock := o.lock.Stall()
	defer unlock()
	// Clear in-memory state to save resources as stalling is indefinite.
	o.invalidateCachedState()
	select {
	case <-ctx.Done():
	case <-releaseCh:
	}
	return api.ErrStalled
```

5. Recovery is **implicit and unbounded**. The driving reminder uses `common.RetryForeverPolicy()`
   (`orchestrator/reminder.go:76`), so the turn is retried forever; the moment it lands on a replica
   whose app registers the version, it succeeds, and any non-stall event clears the state
   (`backend/runtimestate/runtimestate.go:95-96`).

While stalled the instance is deliberately inert: external events rejected (`orchestrator/add.go:67-69`),
purge rejected (`state.go:363-364`), janitor re-dispatch skipped (`invoke.go:222-224`, whose comment
notes re-dispatching "would replay the condition that stalled them").

**Stalling rather than failing is the right call**, and both precedents agree. Temporal's default is
`WorkflowPanicPolicy.BlockWorkflow`, whose doc comment says the workflow "gets stuck in the workflow
task retry loop… after the problem is discovered and fixed the workflows are going to continue without
any additional manual intervention," and warns that its `FailWorkflow` alternative "can cause all open
workflows to fail on a single bug or bad deployment." Azure's `VersionFailureStrategy.Reject` is the
default and is documented as "the safest option because it preserves orchestration state." Dapr landed
in the same place, and the docs correctly frame transient stalls as **expected during a rollout**: *"A
versioned workflow will become stalled when it is started on a new replica, but a subsequent replay is
attempted on an old replica."*

**But there is no un-stall operation.** `ReleaseStall()` has exactly one caller in the repo, inside
`Deactivate` (`orchestrator/orchestrator.go:225`), purely so the parked invocation returns during
teardown. No API, no RPC, no reminder, no CLI verb. The retentioner's own comment — *"stay stalled until
operator intervention"* — describes an intervention mechanism that does not exist. An instance whose
version was deleted and whose code is gone stays stalled until someone redeploys that version or
terminates it.

### 2.5 One favorable property worth documenting

`ContinueAsNew` appears to **re-resolve to `latest`**. When a `CONTINUED_AS_NEW` completion is applied,
the applier builds `NewWorkflowRuntimeState(s.InstanceId, customStatus, []*protos.HistoryEvent{})` — a
fresh, empty history. The new generation therefore carries no pinned version, so the app resolves
`latest` again on its first turn, and the accumulated patch list is wiped with the history.

If confirmed, eternal workflows **self-migrate at every loop boundary**, and `ContinueAsNew` is the
patch-retirement escape hatch that exists today. Temporal reached the same place from the other
direction, GA'ing "upgrade on continue-as-new" in March 2026; Azure exposes it explicitly as
`CompleteOrchestrationAction.newVersion`. Dapr gets it as a consequence of the empty-history
construction.

> Inferred from the applier's construction, not from a test asserting version re-resolution.
> **Unverified.** It needs a test before it is documented as a guarantee — and it should be, because
> it materially changes the advice given to anyone writing an eternal workflow.

---

## 3. Comparison with Temporal

| Dimension | Temporal | Dapr Workflow (1.17/1.18) |
| --- | --- | --- |
| Patching | `GetVersion` (Go/Java); `patched()` (Python/TS/.NET/Ruby) | `IsPatched` (Go/Python/.NET/Java) |
| Where the patch decision is recorded | `MarkerRecorded` event at the evaluation point | List of newly-true names on the per-turn `WorkflowStarted` event |
| Replay decision for an unrecorded patch | `DefaultVersion` (-1) / `false` | `false`, inferred positionally from `historyIndex < totalEvents` |
| Patch retirement | `DeprecatePatch` / raise `minSupported` | **None.** Removal is a permanent stall |
| Version pinning | Worker Deployments, `Pinned` behavior | Named versions via registry `isLatest` |
| Pinning granularity | Per worker *build*, spanning task queues | Per workflow *name*, chosen by the app's registry |
| Mismatch behavior | Block (default), preserving state | Stall, preserving state |
| Un-stall / unblock operation | Reset, terminate, or fix and redeploy | Terminate, `RerunWorkflowFromEvent`, or redeploy |
| Ramping (percentage rollout) | `set-ramping-version --percentage` | **None** |
| Drainage status | `DRAINING` / `DRAINED`, refreshed every 3 min | **None** |
| Count in-flight instances per version | `temporal workflow count -q "…"` (visibility query) | **No supported means** |
| Per-version in-flight *metric* | **None** (Temporal has none either) | None |
| Version visible on instance status | Search attributes + UI | Computed, then dropped by the Dapr API |
| Pre-replay detection | Replayer against recorded histories, in CI | **None**, no harness |
| Cross-app version propagation | n/a | **None** (§4.5) |

Three observations from that table matter more than the rest.

**Dapr's patching is at parity except for `DeprecatePatch`.** This is not a small exception. Temporal's
core state machine documents the whole point of deprecation in one row
([`patch_state_machine.rs`](https://github.com/temporalio/sdk-core/blob/master/crates/sdk-core/src/worker/workflow/machines/patch_state_machine.rs)):

```
| deprecated marker for change | no patched  | Marker ignored, workflow continues as if it didn't exist |
```

A deprecated marker does not fail replay against code that no longer produces it. That is precisely
what makes "finally delete the patch" safe rather than a permanent liability. Without it, **every patch
identifier a Dapr team deploys is a forever commitment**, and it accumulates. This is the one gap I
would call urgent rather than merely valuable, because it is a one-way door that the shipped feature
opened and that teams are walking through right now on the strength of docs that do not disclose it.

**Temporal has no per-version in-flight metric either.** This is worth stating because it reframes the
observability gap. Temporal's drainage is computed by its server running a `CountWorkflowExecutions`
against visibility — `TemporalWorkerDeploymentVersion = '<version>' AND TemporalWorkflowVersioningBehavior
= 'Pinned' AND ExecutionStatus = 'Running'` — on a 3-minute refresh, and the documented operator move is
`temporal workflow count --query "…"`. Azure is the same shape: its `InstanceQuery` has no version
predicate at all, so the supported answer is a client-side filter over a status listing. **Nobody ships
a gauge.** The census is an on-demand count in every mature implementation of this idea, which means
Dapr's gap is not "no metric" — it is that it has no *query* either, and no visibility store to build
one on.

**Temporal's operational layer is the part that has repeatedly failed, and Dapr should not copy it
wholesale.** Temporal has now shipped three generations of Worker Versioning. v1 (Build IDs and
compatibility "version sets," server v1.21.0, June 2023, preview, default-off, never available in
Temporal Cloud) was deprecated in v1.24.0, May 2024 — the release note says the Version Set concept was
"replaced with 'versioning rules' which are more powerful and flexible." That second design was itself
deprecated in v1.28.0 in June 2025 in favor of Worker Deployments, which reached GA in March 2026.

There is no public post-mortem, so causation is inference. But the documented evidence points at the
*retirement signal* as the part that broke: the v1 reachability RPC's own proto comment concedes that
some task queues "may not contain reachability information due to a server enforced limit," and that
raising the limit "can strain the visibility store." The feature existed to tell operators when it was
safe to remove a build, and that was the capped, lossy, expensive part. Users hit the wall with no
answer — *"Legacy versioning: how to delete old version sets?"* went unanswered on the community forum
— and the docs conceded "You can't explicitly delete versions."

> That the compatibility-graph model was abandoned *because* the reachability query was unaffordable is
> my reading, not a maintainer statement. Design discussion lived in a non-archived Slack channel.
> **Unverified.**

The lesson for Dapr: **build the census as an honest, expensive, operator-invoked scan that reports its
own completeness, not as always-on infrastructure.** A cheap-looking index that is silently wrong at
scale is how the first attempt died, and Dapr has no visibility store to lean on.

---

## 4. What remains missing

Ordered by how much I think it matters, not by implementation cost.

### 4.1 `DeprecatePatch` — the one-way door

Highest priority. §3 covers why. A minimal Dapr version requires **no wire change at all**:

```go
// DeprecatePatch marks a patch as retired. Call it in place of IsPatched once every
// instance that could have recorded the patch has completed. The name continues to
// satisfy history-prefix matching, but the workflow no longer branches on it.
func (ctx *WorkflowContext) DeprecatePatch(patchName string)
```

It appends to `encounteredPatches` exactly as a true `IsPatched` would, and returns nothing. Prefix
matching keeps succeeding; the branch and the dead code path go away. `hasPatchMismatch` is untouched.

This is deliberately **weaker than Temporal's**. Temporal writes `deprecated: true` into the marker
payload, which lets the identifier vanish entirely once the code stops producing it. Dapr's
`repeated string patches` has nowhere to put that flag — §2.1 — so a Dapr `DeprecatePatch` makes the
identifier *cheap to keep*, not removable. Full parity would need `repeated string deprecatedPatches = 3`
(additive and wire-safe; old readers ignore field 3) but the real cost is rollout ordering: a history
containing field 3 replayed on an older worker silently loses the deprecation and stalls on prefix
mismatch, converting a clean retirement into an outage during exactly the window where things are
already moving. Ship the no-wire-change version first; add the flag later as a negotiated
`WorkerCapability` if history bloat proves real.

The documented lifecycle is Temporal's, and steps 2 and 3 both depend on §4.2:

1. Add `if ctx.IsPatched("p") { new } else { old }`. Deploy.
2. Once no instance predates the patch: replace with `ctx.DeprecatePatch("p")`, delete the old branch.
3. Once no instance carries `p` in history: delete the call.

### 4.2 A version census — the draining question

**The question:** for workflow `W`, how many non-terminal instances are pinned to version `V`? That is,
can I delete `V` from my codebase? The docs instruct operators to answer it; nothing answers it.

**Shape:** an on-demand API, matching what both precedents actually ship, **not** a gauge or an index.

```
GET /v1.0-alpha1/workflows/dapr/versions?workflow={name}
```

```json
{ "workflow": "order_processing", "scannedAt": "...", "scanDurationMs": 4180, "complete": true,
  "versions": [
    { "version": "order_processing_v3", "nonTerminal": 1204, "stalled": 0 },
    { "version": "order_processing_v1", "nonTerminal": 0,    "stalled": 0 },
    { "version": "",                    "nonTerminal": 3,    "stalled": 0 } ] }
```

Implementation is the scan `dapr workflow list` already performs — `ListInstanceIDs` paged, then a
concurrency-capped fan-out of `FetchWorkflowMetadata` reading `WorkflowMetadata.version`
(`dapr/cli` `pkg/workflow/list.go:161-200`) — plus aggregation.

Four properties must be in the response, not just the docs:

- **`complete`.** Page limit, timeout, or fetch error → `false`, and the counts are a lower bound. A
  partial census that looks total is exactly the failure that killed Temporal's reachability API. It
  must be unusable for a delete decision **by construction**.
- **`scannedAt` / `scanDurationMs`.** The answer is a sample. Temporal carries `last_checked_time`
  alongside drainage status for the same reason.
- **A separate empty-version bucket.** Instances started before the workflow was versioned are neither
  safe nor unsafe; they are *unpinned* and will resolve `latest` on their next turn. Direct analogue of
  Temporal's `TemporalChangeVersion IS NULL` query.
- **Rate limiting and documented cost.** This enumerates the app's whole state store. Operator tool,
  not a dashboard poll.

`nonTerminal` must count dormant instances — parked on a long timer, actor deactivated — which is
precisely why this scans state rather than sampling resident actors.

**Zero is necessary but not sufficient**, and this needs saying as loudly as Temporal says `DRAINED` is
"a signal, not a safety interlock." `nonTerminal: 0` means nothing will *replay* against `v1`; it does
not mean nothing will *start* one, since a stale replica still registering `v1` as latest can create new
instances after the census reads zero. The procedure must be: deploy new latest everywhere → confirm
rollout complete → census → wait out timer horizons → delete.

**Open question, and the largest one here:** `ListInstanceIDs` takes only `continuationToken` and
`pageSize`, with no predicate, and enumeration semantics differ per actor state store. Whether a
reliable full enumeration is achievable, and at what instance count it stops being practical, needs
measurement against real backends before `complete` can be trusted. If it proves unreliable, the honest
fallback is CLI-only aggregation documented as best-effort.

### 4.3 Observability — mostly bug fixes

The cheapest items in this document, and they should land regardless of anything else.

**`statusMap` truncation** — `pkg/api/universal/workflow.go:36-53`:

```go
var statusMap = map[int32]string{
	0: "RUNNING", 1: "COMPLETED", 2: "CONTINUED_AS_NEW", 3: "FAILED",
	4: "CANCELED", 5: "TERMINATED", 6: "PENDING", 7: "SUSPENDED",
}
func getStatusString(status int32) string {
	if statusStr, ok := statusMap[status]; ok { return statusStr }
	return "UNKNOWN"
}
```

durabletask-go computes `ORCHESTRATION_STATUS_STALLED` correctly
(`backend/runtimestate/runtimestate.go:154-161`) and the CLI renders `"STALLED"`
(`dapr/cli` `pkg/workflow/history.go:355`) because it speaks durabletask directly. **The Dapr workflow
API is the only consumer that loses it**, in v1.18.3 and on main. Every dashboard and health check built
on `GET /v1.0-beta1/workflows/dapr/{instanceID}` sees `UNKNOWN`. The hand-maintained map is the defect;
it wants a generated mapping plus an exhaustiveness test over the protobuf enum. Note the fix is
technically a response-value change for existing callers and belongs in release notes.

**Version computed then dropped.** `orchestrator/state.go:344` sets
`Version: wfenginestate.WorkflowVersion(rstate.GetOldEvents())` on `WorkflowMetadata`, and it is on the
wire as `WorkflowMetadata.version = 12` (`backend_service.proto:118`). `pkg/api/universal/workflow.go`
never reads it. Adding `dapr.workflow.version`, `dapr.workflow.stalled.reason` and
`dapr.workflow.stalled.description` to the existing `properties` map is additive and needs no proto
change.

**No version tag in diagnostics.** The complete tag-key set in
`pkg/diagnostics/workflow_monitoring.go:27-33` is `workflow_name`, `activity_name`,
`attestation_kind`, `attestation_result`, `cert_cache_outcome`, `task_type`, `route`. A
`workflow_version` label on the three execution measures would want a config flag defaulting to off,
since cardinality lands hardest on exactly the long-lived deployments that need it most.

**No stall metric at all.** No `Status*` constant corresponds to a stall, so entering the state emits
nothing. A `runtime/workflow/stalled/count{workflow_name, reason}`, incremented where the
`ExecutionStalled` event is appended (once per distinct description, matching the existing dedup), is
**the single alertable signal this feature is missing**. During a rollout stalls are expected and should
decay to zero; a count that does not decay is a stuck deployment, and today that is invisible.

**CLI:** `--filter-status` rejects `STALLED` (`dapr/cli` `pkg/workflow/list.go:53-63`), so the CLI
prints a status it will not filter for. `dapr workflow list` has no version column or filter.

### 4.4 Detection before replay

**General detection at registration time is impossible, and the reason is worth stating precisely.** A
workflow's action sequence is a function of its inputs, activity results, external events and timer
fires; deciding whether two implementations emit the same sequence for all inputs is program
equivalence. Beyond theory, the sidecar never sees the orchestrator — it is arbitrary code in a separate
process in one of five languages, and only the emitted actions cross the boundary. Even "hash the action
sequence" is ill-defined, since two instances of the *same unmodified version* legitimately produce
different sequences on different branches. There is no artifact to hash.

Both precedents concluded the same. Temporal's check is `matchReplayWithHistory` during a workflow task,
with no static analysis and no server-side pre-deploy check anywhere. Azure's DTFx check is structural
and purely at replay (`TaskOrchestrationContext.cs`, 11 throw sites), with no configuration to relax it.

**And the sidecar structurally could not validate even if it wanted to.** The worker stream request is,
in its entirety:

```proto
message GetWorkItemsRequest {
    reserved 1, 2, 3, 10;
    repeated WorkerCapability capabilities = 4;
}
```

One live field, whose only non-reserved value is `WORKER_CAPABILITY_STATEFUL_HISTORY`. No workflow
names, no versions. **The sidecar does not know what its app can run.** Any admission control,
drain interlock, or version-aware routing needs a new protocol element, not new logic. (The sibling
project already did this: `WorkItemFilters` with `OrchestrationFilter { name, repeated versions }` in
`microsoft/durabletask-protobuf`, surfaced as `UseWorkItemFilters()`.) The `"*"` wildcard would
additionally have to be handled explicitly.

**Two kinds of partial detection are possible, and one is unusually cheap.**

**(a) Patch-set static analysis.** The three documented patch-stall causes — removal/rename, reorder,
reuse — are all mechanically checkable at build time for the common case of literal arguments in
straight-line order: extract the ordered patch literals per version, diff against a committed lockfile,
fail the build. Limits that must be declared rather than discovered: runtime-constructed names,
`IsPatched` inside conditionals where lexical order is not evaluation order, calls in helpers reached
from multiple sites, and loops. A linter that cannot statically determine the order must decline to
assert rather than guess. In .NET this fits the existing source generator; elsewhere a build-step
package, matching the accepted proposal's own SDK-tooling section.

**(b) Replay testing against recorded histories — the highest-value item in this document relative to
effort, and it needs no proposal.** This is the documented industry practice: Temporal ships
`WorkflowReplayer` / `Replayer` / `Worker.runReplayHistories` in every SDK, and the CI pattern is list
open executions → download histories → replay against the new build → fail the deploy on divergence.
Dapr has the primitives — `dapr workflow history` and `GetWorkflowHistory` on the durabletask service.
Missing is only an SDK-side harness that drives an orchestrator from a recorded history without a
backend, plus a `dapr workflow replay-check`. No runtime change, no wire change, no design approval
needed. **This should be filed as an issue immediately.** Its structural limits are Temporal's: it
exercises only the paths sampled histories reached, and cannot catch a divergence that would occur at a
future point in an open instance. Sampling test, not proof.

### 4.5 Cross-app versioning

Multi-app workflows (`20250320-RS-multi-app-workflows.md`) let app A's workflow call a child workflow in
app B. **Version state does not cross that boundary.** The child's `ExecutionStartedEvent` carries no
`WorkflowVersion`, so the child resolves `latest` independently in B's registry. If B removes a version,
B's children stall while A's parent sits `RUNNING` on a `ChildWorkflowInstanceCompleted` that never
arrives — the parent shows no stall at all. A per-app census would not surface this. Real gap; deserves
its own proposal; naming it so it is not mistaken for something the above covers.

---

## 5. Discoverability

**A careful reader with the source open missed this feature. That is a finding, not an excuse.**

The gap analysis I was briefed from verified the activity-call signature against
`dapr-ext-workflow` 1.18.3 and correctly concluded there are no activity timeouts. In the *same file of
the same release*, 105 lines below `call_activity` (line 64), sits `is_patched` (line 169). The reader
checked one method and did not scan the class. That is a real failure of method and I am not
attributing it elsewhere — but it is also a signal, because the same conclusion appears in multiple
independent third-party comparisons.

Four concrete contributors, each fixable:

1. **The feature name does not match the search term.** Someone asking "does Dapr have workflow
   versioning" is looking for the word *versioning*. The user-facing surface is `IsPatched` and
   `AddVersionedWorkflow` / `register_versioned_workflow`, and the runtime concept is *stalling*. The
   docs page exists and is titled correctly; it is one level deeper than the workflow features overview
   where a scanning reader stops.

2. **The status is invisible where people look.** §4.3 — the Dapr workflow API returns `UNKNOWN` for a
   stalled instance. Someone probing behavior empirically, which is the reliable way to check a claim
   like this, gets a null result. The feature is *most* invisible exactly when it is doing its job.

3. **A doc/implementation mismatch in the one place a reader would verify.** The versioning page shows
   sample history output containing `reason=VERSION_NAME_MISMATCH`. No such value exists —
   `StalledReason` is `{PATCH_MISMATCH, VERSION_NOT_AVAILABLE, PAYLOAD_SIZE_EXCEEDED}`
   (`orchestration.proto:13-17`) and the applier emits `VERSION_NOT_AVAILABLE`. A reader who greps the
   protos for the documented string finds nothing and reasonably concludes the docs describe something
   unshipped. One-line docs fix; disproportionate cost.

4. **The proposal is the best explanation of the design and is not linked from the docs.** The accepted
   proposal explains *why* both mechanisms exist and how they compose. The docs page explains *how* to
   use them. Nothing connects them, so the conceptual material is only reachable if you already know to
   look in `dapr/proposals`.

Worth adding: the docs' operational guidance currently specifies an impossible action — confirm no
instances run against a version, with no way to confirm. A reader who tries to follow it and hits a dead
end may reasonably infer the feature is incomplete, which is half right in a way that damages
confidence in the half that is complete.

**Suggested fixes, in cost order:** fix `VERSION_NAME_MISMATCH`; link the proposal from the docs page;
fix `statusMap`; add versioning to the workflow features overview under the word *versioning*; and
replace the drain guidance with an honest statement that the check is not currently possible, until
§4.2 exists.

---

## 6. Is "keep instances short-lived" still the answer?

**For a substantial majority of Dapr Workflow users, yes — and the case is stronger than it was before
versioning shipped, not weaker.** Saying so is more useful than overselling the gaps above.

Three reasons, specific to Dapr:

1. **If instances turn over faster than the deploy cadence, none of this machinery is reached.** No
   version outlives its code, no patch is needed, no drain question arises. The accepted proposal frames
   versioning as the answer for when "the developer never has an opportunity to swap out Workflow
   types."
2. **`ContinueAsNew` re-resolves to `latest`** (§2.5, unverified). The canonical long-running shape —
   the infinite loop that is the accepted proposal's own motivating example — self-migrates every
   iteration and wipes its patch list. The workflows most likely to outlive a deploy are the ones with a
   built-in migration point.
3. **The external-ledger discipline is good design independently.** Keeping durable business state in a
   system of record rather than in workflow history keeps history small, replay fast, and sensitive
   payloads out of the durable log — and degrades a versioning problem into a restartable unit of work.

Where it genuinely fails:

- **Human-in-the-loop approvals.** Days or weeks is the business process, not a design choice. The most
  common real case.
- **Workflows that must not restart** — non-idempotent side effects already committed.
- **Multi-app workflows**, where you cannot enforce short-livedness across a team boundary (§4.5).
- **Regulated deployments** where "we believe no old instances remain" is not an acceptable basis for
  deleting code.
- **Anyone who has already adopted patching.** Patches are permanent (§4.1). That is a growing,
  unbounded commitment for every team that took the feature at its word.

The honest summary: §4.3 is bug fixes that should land regardless. §4.1 closes a one-way door the
shipped feature opened and is the only item I would call urgent. §4.2 is the substantial piece, and its
priority scales with how many users actually run long-lived instances — **which nobody currently knows,
because there is no telemetry on version usage.** §4.3 is, among other things, how that becomes
answerable.

---

## 7. What this assessment does not cover

- **Whether the versioning design is right.** It is accepted and shipped; §2 describes it, and I have
  not re-litigated it. My one substantive design observation is that the positional replay heuristic
  (§2.2) differs from Temporal's marker approach in a way that makes false evaluations unrecordable,
  which constrains `DeprecatePatch` — noted, not objected to.
- **Activity versioning.** The accepted proposal explicitly scopes it out; activities need not be
  deterministic. Unexamined here.
- **Performance.** No measurement of what patch accumulation costs a long-lived instance's history, or
  what the §4.2 scan costs at scale. §4.2 flags the latter as the largest open question.
- **The JavaScript SDK**, which ships neither mechanism, consistent with the multi-app docs noting JS
  support is planned.
- **Whether an un-stall API should exist.** §2.4 establishes there is none and that the retentioner
  comment presumes one. Whether that is a gap or a deliberate choice, I did not determine.
- **Empirical validation.** Everything here is read from source, protos and docs at pinned refs. I ran
  no Dapr cluster and executed no workflow. Claims marked unverified — principally §2.5 — are the ones
  where that matters most.

---

## Appendix A — corrections to my own earlier analysis

Recorded because the errors were mine and are likely mirrored elsewhere.

1. **"Dapr's story here is thinner… mitigate with short-lived instances."** Wrong since 1.17.0. Both
   mechanisms ship.
2. **"Versioning long-running instances: Patching + worker versioning | Thin"** in the comparison table.
   The accurate row is *"Patching + named versions; no drainage tooling."*
3. **Method failure worth naming:** I verified the absence of activity timeouts by reading one method
   signature and generalized to a neighbouring feature area without reading the surrounding class.
   `is_patched` was 105 lines away in the file I already had open. Verifying an absence requires
   searching for the thing, not failing to notice it.

What survives unchanged: no activity timeouts and no heartbeat; the 4 MiB payload ceiling; the
history-encryption gaps (all-or-nothing per store, no pluggable codec, no key-free decode path); and
`DurableAgent` plus SPIFFE per-agent identity as genuine Dapr advantages.

## Appendix B — what to do today

1. **Prefer short-lived instances and `ContinueAsNew` loops.** §6. Best answer for most workloads,
   requires nothing from the platform.
2. **Never delete a registered version.** Archive old types as the accepted proposal suggests; accept
   the binary-size and cognitive cost. There is no safe alternative until §4.2 exists.
3. **Use patches sparingly and treat every identifier as permanent**, because it is. Prefer a new named
   version where either would work — a named version is retirable in principle, a patch is not.
4. **Hand-roll the drain check:** `dapr workflow list` plus per-instance
   `dapr workflow history <id> -o wide`, parsing `versionName=`. This is §4.2 without the completeness
   flag, so treat zero as suggestive, not conclusive.
5. **Monitor stalls out of band.** Neither the Dapr API status nor any metric will tell you.
   `dapr workflow list` renders `STALLED` (though it will not filter for it), so poll and grep.
6. **Build a replay harness now** (§4.4b). No runtime change needed, and it is the only item here that
   catches a problem *before* production.
