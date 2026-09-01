# Proposal: Activity Execution Timeouts

**Status:** Draft
**Target repo:** `dapr/proposals`
**Affects:** `dapr/durabletask-protobuf`, `dapr/durabletask-go`, `dapr/dapr`, SDKs, docs
**Author:** Allen Sanborn
**Date:** 2026-09

---

> **Prior art check.** I searched `dapr/proposals` (all 26 merged proposals) and
> `dapr/dapr` issues for an existing activity-timeout or activity-heartbeat
> proposal and found none. The nearest neighbour is
> [`20260318-RS-workflow-external-event-timer-tracking.md`](https://github.com/dapr/proposals/blob/main/20260318-RS-workflow-external-event-timer-tracking.md)
> (Albert Callarisa, accepted), which introduced the `TimerOrigin` oneof this
> proposal extends. This document builds directly on that mechanism rather than
> inventing a parallel one. The search was `grep` over the proposals repo plus
> two GitHub issue-search queries; it is not exhaustive, and if a design
> discussion exists somewhere I did not look, this should be folded into it.

> **Source grounding.** Every claim about current behaviour below cites a file I
> read. Clones were taken 2026-09-01 at `durabletask-go` `18cd4b5`, `dapr`
> `12463d2`, `python-sdk` `e4ad181`, `go-sdk` `9d745f7`, `proposals` `9ca8958`.
Sections marked
> **(design)** are what I am proposing, not what exists. Anything I could not
> confirm is marked **unverified**.

---

## 1. Abstract

Dapr Workflow can bound how long a workflow *waits*. It cannot bound how long an
activity *works*.

`waitForExternalEvent` takes a timeout. `CreateTimer` exists. `RetryPolicy` has
`RetryTimeout`. But there is no way to say "this activity attempt gets ten
minutes." An activity body that wedges — a hung HTTP call with no client-side
deadline, a model inference that never returns, a lock wait that never resolves —
is invisible to the engine and runs forever. The engine will not reclaim it,
will not fail it, and will not tell anyone.

This proposal adds two timeouts, deliberately not four:

1. **`startToCloseTimeout`** — a per-attempt bound, enforced by the Dapr activity
   actor that owns the execution, surfaced to the orchestrator as an ordinary
   `TaskFailed` history event so replay stays deterministic and the existing
   retry machinery applies unchanged.
2. **`scheduleToCloseTimeout`** — a hard ceiling on the whole attempt chain,
   enforced orchestrator-side as a durable timer racing the activity task, using
   exactly the mechanism `WaitForSingleEvent` already uses.

It deliberately does **not** add `scheduleToStartTimeout` (§4.2) and does
**not** add activity heartbeat (§7). Both cuts are argued, not assumed.

Both new fields default to unset, which means infinite, which is exactly
today's behaviour. Nothing existing changes.

---

## 2. Background

### 2.1 What Dapr already has

Dapr Workflow is the Durable Task Framework with an actor-based backend. The
authoring surface lives in `dapr/durabletask-go` (`task/`, and the newer
`workflow/` package the Go SDK now re-exports); execution is driven by the
workflow, activity, and executor actor targets in
`dapr/dapr/pkg/actors/targets/workflow/`.

The pieces relevant here already exist and are surprisingly close to what is
needed:

- **Durable timers with typed origins.** `CreateTimerAction` and
  `TimerCreatedEvent` carry an `origin` oneof —
  `TimerOriginCreateTimer`, `TimerOriginExternalEvent`,
  `TimerOriginActivityRetry`, `TimerOriginChildWorkflowRetry`
  (`durabletask-go/api/protos/history_events.pb.go`, the generated forms of the
  schema added by the external-event-timer proposal). The oneof was introduced
  explicitly so that new timer origins could be added later without breaking
  consumers.

- **A working timeout precedent.** `WaitForSingleEvent`
  (`durabletask-go/task/orchestrator.go:670`) implements its timeout as a
  durable timer raced against the event, entirely in orchestrator code. The
  timer is created through `createExternalEventTimerInternal`
  (`orchestrator.go:636`); whichever side resolves first wins, and the loser is
  simply ignored. The comment in that function is the single most load-bearing
  sentence in this whole design space:

  > *"The event won the race: the task was already completed by
  > onExternalEventRaised and deregistered. Nothing cancels the durable timer,
  > so its TimerFired still arrives later; it must not cancel the delivered
  > result…"*

  Racing a durable timer against a pending resolution, and orphaning the loser,
  is already how this engine bounds a wait.

- **Retry as orchestrator-side policy.** `CallActivity` with a `RetryPolicy`
  wraps the schedule in `internalScheduleTaskWithRetries`
  (`orchestrator.go:539`), which on failure computes a delay via
  `computeNextDelay` (`orchestrator.go:575`) and schedules a durable timer with
  `TimerOriginActivityRetry`. `RetryTimeout` is evaluated there against
  `ctx.CurrentTimeUtc` — the replay-safe clock — not `time.Now()`.

- **An existing liveness oracle.** The activity actor tracks in-flight
  executions and can already answer "is this execution still alive?" without any
  application cooperation.
  `dapr/pkg/runtime/wfengine/backends/actors/actors.go` exposes
  `ActivityExecutionHeld(instanceID, taskID)` — "reports whether the engine on
  this host currently holds a completion registration for the given activity
  work item" — wired into the activity target as
  `factory.executionHeld` and consumed by `staleClaim`
  (`dapr/pkg/actors/targets/workflow/activity/execute.go:184`). This matters
  enormously for §7.

- **A result-publishing path that already handles failure.**
  `publishResult` (`activity/publish.go`) posts `wi.Result` back to the workflow
  actor via `AddWorkflowEvent`, and already branches on whether that result is a
  `TaskCompleted` or a `TaskFailed`. A synthesized timeout failure needs no new
  delivery mechanism.

- **Resolution-event dedup, keyed the right way.**
  `addEventWithDedup` (`durabletask-go/backend/runtimestate/runtimestate.go:59`)
  drops a second resolution event for an already-resolved task id, and
  `dedup.Of` maps both `TaskCompleted` and `TaskFailed` to the same
  `(KindTask, taskScheduledId)` key — asserted directly in
  `backend/runtimestate/dedup/dedup_test.go` (`"TaskFailed shares Task kind"`).
  A late real completion arriving after a synthesized timeout failure for the
  same task id is therefore already dropped by existing code. This is the
  mechanism that makes §4.5 cheap.

### 2.2 The gap

There is no timeout field anywhere on the activity path. Concretely:

| Surface | Evidence |
| --- | --- |
| `ScheduleTaskAction` | Fields are `name`, `version`, `input`, `taskExecutionId`, `historyPropagationScope`. No timeout. (`api/protos/orchestrator_actions.pb.go`) |
| `TaskScheduledEvent` | Same set plus trace context and rerun info. No timeout. (`api/protos/history_events.pb.go`) |
| `callActivityOptions` (Go) | `rawInput`, `retryPolicy`, `targetAppID`, `targetAppNamespace`, `propagationScope`. (`durabletask-go/task/activity.go:26`) |
| `call_activity` (Python) | `(activity, *, input, retry_policy, app_id, propagation)`. (`python-sdk/dapr/ext/workflow/dapr_workflow_context.py:64`) |
| `RetryPolicy` | `MaxAttempts`, `InitialRetryInterval`, `BackoffCoefficient`, `MaxRetryInterval`, `RetryTimeout`, `Handle`. (`durabletask-go/task/activity.go:34`) |
| `ActivityWorkItem` | `SequenceNumber`, `InstanceID`, `NewEvent`, `Result`, `LockedBy`, `Properties`, `IncomingHistory`. No lease, no deadline, no expiry. (`durabletask-go/backend/workitem.go`) |

The word "heartbeat" does not appear in the activity execution path at all.

And the absence is deliberate, not accidental. `driveActivity` in
`dapr/pkg/actors/targets/workflow/activity/drive.go` says so in a comment:

> *"No per-attempt deadline: activities run for arbitrary lengths and a
> reminder-fired execution is equally unbounded. The bound is driveCtx."*

`driveCtx` is the factory drive context, cancelled on placement churn or process
shutdown. It is a lifecycle bound on the host, not a bound on the work.

`execute.go` states the consequence even more directly, in the doc comment on
`staleClaim`:

> *"A live execution of any length keeps its completion registration in the
> engine, so it is never stale regardless of age (long-running activities are
> not re-executed)."*

That is correct and desirable behaviour *given no timeout exists* — you must not
re-execute a long activity merely because it is long. It also means a wedged
activity and a legitimately slow activity are indistinguishable to the engine,
forever, by construction.

### 2.3 Why `RetryTimeout` is not a substitute

`RetryTimeout` is checked in `computeNextDelay`, which is called from
`internalScheduleTaskWithRetries`'s `onAwaitResult` — that is, **only after an
attempt has returned an error**. An attempt that never returns never reaches
that check. A workflow configured with `MaxAttempts: 3, RetryTimeout: 5m` and a
first attempt that hangs will sit there for five hours or five days; the
five-minute budget is never consulted, because the code path that consults it is
downstream of a completion that never arrives.

This is worth stating in the proposal because it is the most common thing people
reach for, and it looks like it should work.

### 2.4 Why this is acute now

Three trends, all of which Dapr is actively courting:

- **Agent activities are long and externally blocking by nature.** A model call,
  a tool invocation, an MCP round trip. `DurableAgent` and the 1.18 `MCPServer`
  resource put exactly this shape of work inside activities.
- **At-least-once plus no bound is a compounding hazard.** Dapr Workflow
  guarantees at-least-once activity execution, so a host lost mid-activity means
  the activity re-executes. Without a per-attempt bound, "lost mid-activity" is
  a state the system can sit in for an unbounded time before anything notices.
- **The asymmetry is user-visible and reads as a bug.** `wait_for_external_event`
  takes a `timeout`; `call_activity` does not. Users find this and file issues
  about it, because it looks like an oversight rather than a design boundary.

### 2.5 What Temporal actually does, and what it costs

Worth being precise here, because "Temporal has four timeouts" is usually where
this comparison stops and the interesting part is downstream of that.

Temporal's four are schedule-to-start, start-to-close, schedule-to-close, and
heartbeat; **all four default to infinity** except that start-to-close inherits
schedule-to-close ([Detecting Activity
Failures](https://docs.temporal.io/encyclopedia/detecting-activity-failures)).
So even Temporal's out-of-the-box default is "unbounded" — the difference is
that Temporal lets you say otherwise.

Two details from Temporal's own documentation reshape this proposal:

1. **Timeout does not, by itself, stop the activity.** Temporal's docs state
   that *"Activities must heartbeat to receive cancellations from a Temporal
   Service"* ([Activity
   Execution](https://docs.temporal.io/activity-execution)). A non-heartbeating
   Temporal activity whose start-to-close fires is **orphaned** — the server
   marks it failed and retries, and the original body keeps running until it
   finishes on its own. Cancellation-on-timeout is not a property of timeouts in
   Temporal; it is a property of heartbeating.

2. **Heartbeat is expensive enough that Temporal aggressively throttles it.**
   The worker throttles to the smaller of `heartbeatTimeout × 0.8` and
   `defaultHeartbeatThrottleInterval` (30s), capped at
   `maxHeartbeatThrottleInterval` (60s), persisting only the most recent
   heartbeat within a throttle window. The write amplification is real enough
   that the SDK ships a rate limiter for it by default.

Fact (1) is the reason §4.5 chooses orphan-and-drop without embarrassment: it is
parity with Temporal's non-heartbeating case, which is the overwhelmingly common
case. Fact (2) is half the argument in §7.

I could not confirm from the public docs precisely which Temporal component
holds each timer (the encyclopedia page is explicit about behaviour and vague
about placement), so this proposal does not lean on Temporal's internal
enforcement topology — **unverified**, and it does not need to be verified for
the argument to hold.

---

## 3. Goals and non-goals

### Goals

- Give a workflow author a way to bound a single activity attempt.
- Give a workflow author a way to bound an entire activity call including
  retries.
- Enforce both in a way that keeps orchestrator replay a pure function of
  recorded history.
- Reuse the existing `TaskFailed` / durable-timer machinery rather than adding
  new history event types.
- Compose predictably with `RetryPolicy`, including `RetryTimeout`.
- Be entirely additive: unset means infinite, which is today's behaviour, so no
  existing workflow changes semantics.

### Non-goals

- **Activity heartbeat.** Argued out in §7, with an explicit statement of what
  replaces it and what remains uncovered.
- **`scheduleToStartTimeout`.** Argued out in §4.2.
- **Cancellation propagation into the activity body.** Deferred to phase 3 with a
  concrete design sketch (§4.5); phase 1 orphans the work and drops the late
  result.
- **Workflow-level (orchestration) timeouts.** A separate concern with a
  different owner; out of scope.
- **Making activities idempotent.** At-least-once remains the guarantee. This
  proposal makes the failure *detectable*, which — see §13 — slightly *increases*
  the number of concurrent duplicate bodies in the wedged case.
- **Retro-applying timeouts to in-flight instances.** The timeout is read from
  the recorded `TaskScheduledEvent`; deploying new code does not change how
  already-scheduled tasks behave.

---

## 4. Design

Everything in §4 is **(design)** unless it cites a file.

### 4.1 Which timeouts, and why two

| Temporal timeout | Verdict | Reasoning |
| --- | --- | --- |
| start-to-close | **Add** | The only one that bounds a hung attempt. This is the entire gap. |
| schedule-to-close | **Add** | Needed because a per-attempt bound does not bound a retry chain, and because it is the only durable backstop when a host dies mid-attempt (§4.4). |
| schedule-to-start | **Cut** (§4.2) | Measures queue dwell time in a system with a queue. Dapr's dispatch model has no queue for it to measure. |
| heartbeat | **Cut** (§7) | Dapr already has a cheaper liveness oracle; heartbeat's unique remaining value is progress checkpointing, which is better served by an existing building block. |

Two knobs, not four. Every additional timeout is a thing an author must reason
about at every call site, and Temporal users routinely misconfigure the
interaction between the four. If a concrete case for a third emerges, adding it
later is a proto field, not an architectural change.

### 4.2 Why `scheduleToStartTimeout` is cut

In Temporal, schedule-to-start answers "is anyone polling this task queue?" It is
a queue-depth pathology detector, and it presupposes a queue that work sits in.

Dapr's dispatch is not a queue. Reading `handleInvoke`
(`dapr/pkg/actors/targets/workflow/activity/invoke.go`), a scheduled activity
either:

- takes the **fast path** — `localDrive` spawns the execution immediately on this
  host when the dispatching orchestrator certified its janitor backstop is
  armed; or
- creates a **durable reminder** with `dueTime` clamped to now
  (`activity/reminder.go`, `createActivityReminder`) and a
  `RetryForeverPolicy()` failure policy.

There is no queue in which work waits for a poller. What can happen instead is
that the app is unreachable and the reminder retries forever with jittered
backoff. That is a genuinely unbounded wait — but it is a *health* condition, not
a scheduling-latency condition, and the right instrument for it is
`scheduleToClose` (which covers it, because it starts counting at schedule time)
plus a metric. Adding a separate knob that in Dapr's model would fire under
exactly the same circumstances as `scheduleToClose` buys confusion, not control.

One honest caveat: the fast path elides the reminder entirely, so "dispatched"
and "started" are separated by a goroutine spawn rather than a scheduler round
trip. On the non-fast path the gap includes a scheduler job upsert and trigger.
The gap is therefore not always zero — it is just never a *queue*, and never
unbounded independently of the schedule-to-close clock.

### 4.3 `startToCloseTimeout` — the crux

This is design question 2, and getting it wrong makes the rest worthless. The
constraint is absolute: **the orchestrator may not read a wall clock.** A timeout
that fires must be a recorded history event that replays identically forever.

#### Schema

```protobuf
// orchestrator_actions.proto
message ScheduleTaskAction {
    string name = 1;
    google.protobuf.StringValue version = 2;
    google.protobuf.StringValue input = 3;
    string taskExecutionId = 5;
    optional HistoryPropagationScope historyPropagationScope = 6;

    // Maximum duration of a single execution attempt of this activity,
    // measured from when the activity actor begins the app roundtrip.
    // Absent means unbounded (current behaviour).
    optional google.protobuf.Duration startToCloseTimeout = 7;
}

// history_events.proto
message TaskScheduledEvent {
    // ... existing fields 1-7 ...

    // Persisted so a re-dispatch (janitor, rerun, placement handoff) can
    // re-arm the same bound, for the same reason historyPropagationScope
    // is persisted on this event.
    optional google.protobuf.Duration startToCloseTimeout = 8;
}
```

Persisting it on the event is not optional. The existing comment on
`TaskScheduledEvent.historyPropagationScope` gives the precedent verbatim:
*"Persisted on the event so rerun can re-issue the task with the same scope
after the action has been discarded."* A re-dispatch reads the event, not the
action, so an unpersisted timeout would silently vanish on recovery.

#### Who owns the timer

The **activity actor on the host running the execution**, not the orchestrator
and not the scheduler.

The execution path is `executeActivity` → `claim` → `runOwned` → the app
roundtrip, with the result delivered by `watchAndPublish` / `publishResult`
(`activity/execute.go`, `activity/publish.go`). The deadline is armed at the
point the app roundtrip begins and disarmed when the inflight `Call` settles.

Concretely: an in-process timer (or a `context.WithTimeout` on the executor
call), **not** a Dapr reminder.

That choice needs defending, because a reminder is the durable option and this
codebase is built out of reminders. Three reasons:

1. **The failure mode a durable timer protects against is already covered.** A
   durable timer's advantage is surviving host death. But if the host dies, the
   activity body dies with it, and recovery already exists: the orchestrator's
   janitor re-dispatches the unresolved `TaskScheduled` event, gated on the
   durable execution-claim record (`activity/invoke.go`,
   `gateJanitorRedispatch`). A durable timeout timer would fire into a world
   where the thing it was bounding is already gone.

2. **The failure mode we are adding protection for requires a live host.** A
   wedged activity is by definition a body still running in a process that is
   still up. An in-process timer is exactly sufficient, and it is the only
   mechanism that has direct access to the thing it needs to stop.

3. **Reminders are the cost this codebase is actively engineering away.** The
   whole fast path exists to elide *"its job upsert/delete commit pair and the
   scheduler trigger round trip"* (`activity/invoke.go`). Adding a scheduler job
   per activity to implement timeouts would re-introduce, for every timed
   activity, precisely the cost the fast path was built to remove.

The residual gap — elapsed time is lost when a host dies and the attempt
restarts — is real, is bounded by `scheduleToClose`, and is stated in §13.

#### What is written to history

Nothing new. On expiry, the activity actor synthesizes the result it would
have published anyway:

```go
wi.Result = &protos.HistoryEvent{
    EventId: taskEvent.EventId,
    EventType: &protos.HistoryEvent_TaskFailed{
        TaskFailed: &protos.TaskFailedEvent{
            TaskScheduledId: taskEvent.EventId,
            TaskExecutionId: ts.TaskExecutionId,
            FailureDetails: &protos.TaskFailureDetails{
                ErrorType:    "DaprWorkflowActivityStartToCloseTimeout",
                ErrorMessage: "activity attempt exceeded startToCloseTimeout of 10m0s",
                IsNonRetriable: false,
            },
        },
    },
}
```

and hands it to the existing `publishResult`, which posts it to the workflow
actor through `AddWorkflowEvent` exactly as it does a real failure — that
function already branches on `wi.Result.GetTaskFailed() != nil`.

This is the same reasoning the external-event-timer proposal used when it chose
to extend an existing event rather than add one: *"Add a new event type to the
workflow history… would grow the history size, which we want to keep as lean as
possible."*

#### Why replay stays deterministic

The orchestrator never learns that a timeout happened as a *timeout*. It receives
a `TaskFailed` for task id N, indistinguishable in mechanism from an activity
that threw. `internalScheduleTaskWithRetries` handles it through the existing
`onAwaitResult` path. Replay reads the same `TaskFailed` from history and
produces the same actions. No wall-clock read occurs anywhere on the orchestrator
path.

The only clock read is inside the activity actor, which is not replayed. That is
the whole trick, and it is why enforcement belongs there.

#### Why the late completion cannot corrupt anything

Suppose the wedged activity finishes ninety seconds after the timeout fired and
its real `TaskCompleted(N)` reaches the workflow actor. `addEventWithDedup`
(`runtimestate.go:59`) checks `dedup.Of(e)` → `(KindTask, N)`, finds the
already-recorded `TaskFailed(N)` under the same key, and drops it. This is
existing code with existing test coverage
(`backend/runtimestate/dedup/dedup_test.go`), and the activity actor's own
comments already rely on it: *"a completion of the evicted execution arriving
late is dropped by the orchestrator's duplicate-completion dedup."*

This is the single most fortunate fact in the design. The dedup key was chosen
for a different reason and it happens to be exactly right for this.

### 4.4 `scheduleToCloseTimeout` — orchestrator-side, durable

`startToClose` bounds one attempt. It does not bound a chain of them, and it
does not survive a host dying mid-attempt (the replacement attempt gets a fresh
budget). Something has to be the durable outer bound.

That something must be orchestrator-side, because only the orchestrator knows
about the retry chain — retries are constructed in
`internalScheduleTaskWithRetries`, entirely in orchestrator code.

Mechanism: exactly `WaitForSingleEvent`'s. A durable timer created at schedule
time, raced against the activity task, with a new origin on the existing oneof:

```protobuf
// Indicates the timer bounds the total lifetime of an activity call,
// including retries.
message TimerOriginActivityTimeout {
    string taskExecutionId = 1;
}
```

added to the `origin` oneof on both `CreateTimerAction` and `TimerCreatedEvent`
alongside `TimerOriginActivityRetry`. This is precisely the extensibility the
external-event proposal built the oneof for — it named *"child workflow
timeouts"* as an anticipated future member.

When the timer wins, the task is failed with a **non-retriable**
`DaprWorkflowActivityScheduleToCloseTimeout` and the retry wrapper stops. When
the activity wins, the timer is orphaned and its later `TimerFired` ignored —
the same orphaning `WaitForSingleEvent` already does and already guards against
in code.

`scheduleToCloseTimeout` therefore needs no new runtime behaviour at all. It is
pure SDK-side orchestration over primitives that ship today. Notably, this half
of the proposal could ship on its own.

### 4.5 Abandoned work: orphan and drop

**Decision: orphan the body, drop the late result. Do not propagate
cancellation in phase 1.**

The alternative — cancelling the activity body's context — is better, and I want
to be clear that it is better, and equally clear about what it costs today.

There is **no cancellation channel to an activity worker**. The work-item
protocol is one-directional for dispatch: `GetWorkItems` is a *server-streaming*
RPC (`api/protos/orchestrator_service_grpc.pb.go`) carrying a `WorkItem` whose
`request` oneof has exactly two members, `workflowRequest` and
`activityRequest`. Completions come back as separate unary
`CompleteActivityTask` calls. There is no message that means "stop."

Adding one is not a small change. It requires: a new `WorkItem` variant in
`durabletask-protobuf`; daprd tracking which stream is executing which task so it
can target the notice; every SDK's activity executor plumbing cancellation into
the activity function's context; and — the part that is not a code change at all
— a **new obligation on user code**, which must now honour context cancellation
for the feature to do anything. An activity that ignores its context gets
cancellation delivered and carries on regardless, which is precisely the wedged
activity we are trying to stop.

So phase 1 orphans. What this actually costs:

- The wedged body keeps consuming CPU, memory, connections, and any external
  resource it holds, until it returns on its own or the process restarts.
- If the timeout was retriable, the retry attempt runs **concurrently with the
  orphan**. Before this proposal, at-least-once produced duplicate bodies only
  after a crash. After it, a timeout produces them too, on a live host. This is a
  real new hazard and §13 says so.
- Any side effect the orphan performs lands after the workflow has already moved
  on.

What makes it defensible anyway: it is **exactly what Temporal does for a
non-heartbeating activity** (§2.5), it is exactly what this engine already does
for the external-event timer race, and the alternative — no timeout at all — has
all the same problems plus no detection.

**Phase 3 design sketch (design, not committed).** Because `GetWorkItems` is
already a live server→client stream, Dapr does not need a heartbeat to deliver
cancellation the way Temporal does. Add a third `WorkItem` variant,
`cancelActivityRequest { instanceId, taskId, taskExecutionId, reason }`, pushed
down the same stream to the worker holding the execution. The SDK cancels the
activity context; the activity's late completion is dropped by the existing
dedup either way, so delivery can be best-effort with no correctness
consequence. This is strictly better than Temporal's design on this specific
point, and it is worth saying so in the proposal — the coupling of cancellation
to heartbeating in Temporal is an artefact of long-polling, not a requirement.

### 4.6 Composition with `RetryPolicy`

This is where a two-timeout design earns its keep or becomes a footgun. The rules:

| | Scope | Enforced by | Retriable? |
| --- | --- | --- | --- |
| `startToCloseTimeout` | one attempt | activity actor | yes, by default |
| `RetryPolicy.RetryTimeout` | chain, checked between attempts | orchestrator | n/a — stops retrying |
| `scheduleToCloseTimeout` | chain, wall-clock durable | orchestrator | no, terminal |

1. **A start-to-close expiry is an ordinary retriable failure.** It surfaces as
   `TaskFailed` with `errorType = DaprWorkflowActivityStartToCloseTimeout`, so
   `RetryPolicy.Handle(err)` sees it and an author who wants "never retry a
   timeout" writes exactly the predicate they already know how to write.

2. **`RetryTimeout` keeps its current meaning, unchanged.** It is still evaluated
   in `computeNextDelay` between attempts. The §2.3 defect — that it cannot see a
   hung attempt — is *fixed as a side effect*: once every attempt is bounded by
   `startToClose`, the interval between `RetryTimeout` checks is bounded too. The
   field becomes correct rather than becoming obsolete, and needs no
   modification. That is a strong argument for not touching it.

3. **`scheduleToClose` is a ceiling, not a participant.** When it fires the task
   fails terminally regardless of remaining attempts. Effective bound on any
   single attempt is `min(startToClose, scheduleToClose − elapsed)`.

4. **Validation, at schedule time, in the SDK.** `startToClose > scheduleToClose`
   is a configuration error and must be rejected where the author can see it, not
   discovered as strange runtime behaviour. Same for non-positive durations.

5. **No implicit derivation.** Temporal defaults `startToClose` to
   `scheduleToClose`. This proposal does not: each is independently unset by
   default, because deriving one from the other is the source of a good share of
   Temporal's timeout confusion, and Dapr has the luxury of not inheriting it.

### 4.7 SDK surfaces

Go (`durabletask-go`, used directly by `dapr/go-sdk` — note that at `go-sdk`
`9d745f7` there is no `workflow` package in the Go SDK itself; its own examples
import `github.com/dapr/durabletask-go/workflow`, so that is the surface to
change):

```go
ctx.CallActivity(ProcessDocument,
    workflow.WithActivityInput(doc),
    workflow.WithActivityStartToCloseTimeout(10*time.Minute),
    workflow.WithActivityScheduleToCloseTimeout(1*time.Hour),
    workflow.WithActivityRetryPolicy(&workflow.RetryPolicy{MaxAttempts: 3}),
)
```

adding two fields to `callActivityOptions` (`durabletask-go/task/activity.go:26`).

Python (`dapr-ext-workflow`), extending the signature at
`dapr_workflow_context.py:64`:

```python
yield ctx.call_activity(
    process_document,
    input=doc,
    start_to_close_timeout=timedelta(minutes=10),
    schedule_to_close_timeout=timedelta(hours=1),
    retry_policy=RetryPolicy(max_number_of_attempts=3),
)
```

.NET and Java: **unverified.** I did not read `dapr/dotnet-sdk` or
`dapr/java-sdk` for this draft. Both surface activity options through a
`TaskOptions`-shaped type and the fields should land there, but the exact shape
needs checking before filing.

Keyword-only / option-func in every language, so the addition is source
compatible.

---

## 5. What application code looks like

The payoff is small and that is the point:

```python
# Before: if the model call wedges, this workflow never advances again.
result = yield ctx.call_activity(call_model, input=prompt)

# After: bounded, retried twice, hard ceiling at 20 minutes.
result = yield ctx.call_activity(
    call_model,
    input=prompt,
    start_to_close_timeout=timedelta(minutes=5),
    schedule_to_close_timeout=timedelta(minutes=20),
    retry_policy=RetryPolicy(max_number_of_attempts=3),
)
```

The activity body is unchanged. It does not learn about the timeout, does not
heartbeat, and does not need a cooperating cancellation check — in phase 1 it
cannot receive one.

Two lines of workflow code convert "hangs forever, silently" into "fails in five
minutes, retries, gives up at twenty, and shows up in a metric."

---

## 6. Backward compatibility and defaults

**The default is unset, and unset means infinite.** No global default, no
configuration-level default, no derived default.

This is a deliberate refusal, and the reason is that any non-infinite default
breaks exactly the workloads that most need not to break. The population of
activities that today run for thirty minutes without complaint is not small, and
it is precisely the ML-inference and batch-processing population. Shipping a
default of, say, ten minutes converts a working production system into a
retry-storming one on upgrade, and the operator's only signal is a flood of
timeout failures with no prior warning.

What is offered instead, and should ship in the same release:

**A report-only observation threshold.** A runtime configuration knob —
`workflow.activityDurationWarnAfter`, unset by default — that emits a warn log
and increments a metric when an activity attempt exceeds it, without failing
anything. Operators run it for a release, look at
`dapr_workflow_activity_execution_duration_seconds`, discover what their real
distribution is, and then set per-call-site timeouts from evidence. Turning on a
timeout is then a decision, not a gamble.

Other compatibility properties:

- **Wire compatibility.** Both fields are `optional` on proto3 messages. An older
  daprd or SDK ignores them; a newer one reading old history sees them absent
  and behaves as today. Same guarantee the external-event proposal claimed for
  `origin`.
- **Rolling upgrade window.** A new SDK scheduling a timeout against an old
  daprd gets **no enforcement, silently** — the field arrives and nothing reads
  it. This must be documented rather than papered over. Options: gate on a
  runtime capability advertisement, or accept the window as the external-event
  proposal did (*"Existing workflows that resume after an SDK upgrade will not
  have the new field on previously-created timers. This is acceptable."*). I lean
  toward accepting it and documenting it, but flag it as **open** (§9.3).
- **In-flight instances.** The bound is read from the recorded
  `TaskScheduledEvent`, so a task scheduled before the upgrade keeps its recorded
  (absent) timeout even after the code that scheduled it is redeployed. Replay of
  an old history is unaffected.
- **Feature gate.** `WorkflowActivityTimeouts`, defaulting off for one release.
  With the gate off, a timeout field present in a schedule action is rejected at
  schedule time with an actionable error rather than silently ignored — the same
  fail-loud stance the delegated-identity proposal takes for `onBehalfOf`.

---

## 7. Why heartbeat is not part of this

This is design question 4, and the answer is a clear no — with a clear statement
of what covers the gap.

**What heartbeat is for in Temporal, decomposed:**

1. *Liveness* — the worker is still alive and holding this activity.
2. *Progress liveness* — the worker is alive and the body is making progress,
   distinct from alive-but-wedged.
3. *Progress checkpointing* — recording "processed 4,300 of 10,000 rows" so a
   retry can resume.
4. *Cancellation delivery* — the response to a heartbeat carries the cancel
   signal (§2.5).

Taken in turn:

**(1) is already solved, for free, and better.** `ActivityExecutionHeld(instanceID,
taskID)` (`wfengine/backends/actors/actors.go`) reports whether the engine holds
a completion registration for a given activity work item. It is derived from the
work-item stream's connection state, costs zero writes, is continuous rather than
sampled, and is already load-bearing: `staleClaim`
(`activity/execute.go:184`) uses it today to decide whether an in-flight claim is
provably dead. Dapr's persistent connection gives it, structurally, a liveness
signal that Temporal's long-polling model has to simulate with periodic writes.
Adding heartbeat for liveness would be paying for something already owned.

**(2) is what `startToCloseTimeout` does**, bluntly rather than adaptively.
Heartbeat catches a wedged body faster than a long start-to-close would, and that
is its real advantage. But "faster" here means the difference between one
timeout budget and one heartbeat interval, and the author can simply set a
tighter start-to-close. Heartbeat buys latency, not capability, and it buys it at
a write per beat per activity.

**(3) is genuinely not covered, and is not the workflow engine's job.** An
activity that wants resumable progress can write it to a Dapr state store keyed
on `taskExecutionId` — which the code already keeps stable across retry attempts
(`internalScheduleTaskWithRetries` threads a single `taskExecutionId` through
the whole retry chain, `orchestrator.go:539`). That is a five-line pattern using
a building block that already exists, with no new engine machinery, and it lets
the author choose the checkpoint granularity instead of coupling it to a
liveness interval. It should be documented as the recommended pattern.

**(4) does not require heartbeat in Dapr** (§4.5). `GetWorkItems` is already a
live server→client stream. Cancellation can be pushed down it. Temporal couples
cancellation to heartbeating because long-polling gave it no other channel;
Dapr has one.

**The cost avoided.** A heartbeat is a durable write per beat per in-flight
activity. Under Dapr's actor backend that write lands in the same state store as
workflow history, on the same actor-turn path. A thousand concurrent activities
heartbeating at Temporal's floor throttle of 30s is ~33 additional state-store
writes per second of pure liveness traffic against a store that is also the
critical path for every workflow turn. That is a material regression to buy
something (1) already provides.

**So: what happens to the wedged-20-minute activity?** It is caught by
`startToCloseTimeout`. Set it to five minutes and the wedge is detected in five
minutes, published as a `TaskFailed`, retried per policy, and visible in
`dapr_workflow_activity_timeouts_total`. What you do *not* get, relative to
heartbeat, is the ability to distinguish "wedged at minute two" from "legitimately
slow, will finish at minute nineteen" — so an activity with a genuinely wide
duration distribution must set its timeout to the tail, and a wedge inside that
distribution is detected only at the tail. That is the residual cost of this cut,
it is stated in §13, and it is the case that would justify revisiting heartbeat
later.

---

## 8. Alternatives considered

**Do it entirely SDK-side (orchestrator races a timer against the activity).**
Zero runtime change, works with today's daprd, and could be prototyped this
afternoon by copying `WaitForSingleEvent`. It is genuinely tempting and it is the
recommended interim pattern (Appendix A). Three things kill it as the
destination: the orchestrator cannot distinguish "hung" from "slow" any better
than the actor can but has strictly less information; the abandoned activity is
never even *known* to be abandoned by the component that owns it, so the actor
keeps holding its inflight claim and its engine registration; and every SDK must
reimplement the race identically or timeout semantics silently diverge per
language. The last one is the decisive one — this is exactly the class of
divergence the external-event-timer proposal was written to eliminate.

**Enforce start-to-close with a durable Dapr reminder instead of an in-process
timer.** Survives host death, which sounds strictly better. It is not: host death
already has a recovery path (janitor re-dispatch, §4.3), so the reminder would be
paying a scheduler job upsert/delete pair per activity to cover a case that is
covered. Reconsider only if in-process timing proves unreliable under load.

**Put the timeout on the component/configuration rather than the call site.** An
operator-set default per app or per activity name. Attractive for
retrofitting onto existing code with no source changes, and rejected because the
right timeout is a property of what the activity *does*, which the author knows
and the operator does not. The `activityDurationWarnAfter` knob in §6 is the
operator-facing half of this idea, kept in report-only form where it is safe.

**Extend `RetryPolicy` with a `PerAttemptTimeout` field instead of adding a
top-level option.** Fewer concepts, and it puts the two chain-scoped controls
next to each other. Rejected because it forces authors who want a timeout but no
retries to construct a `RetryPolicy` with `MaxAttempts: 1`, which is
confusing, and because `startToClose` is meaningful with no retry policy at all.

**Wire timeouts into the resiliency building block.** Dapr already has
`resiliency` policies with timeouts, and reusing them would be idiomatic.
Rejected because resiliency timeouts bound a *call* made by the sidecar, and an
activity execution is not a call the sidecar is waiting on — it is a work item
handed to a worker over a stream, with the result arriving later by a different
path. The shapes do not match. Worth stating explicitly in the proposal because
it is the first thing a Dapr maintainer will ask.

**Ship cancellation propagation in phase 1.** Correct end state, wrong first
step. It couples a proto change, an N-SDK change, and a new obligation on user
code to a feature that delivers most of its value without any of them.

---

## 9. Open questions

### 9.1 Does the timeout clock start at claim or at app dispatch?

`startToClose` is defined above as starting when the app roundtrip begins. But
`executeActivity` (`activity/execute.go`) can park a *follower* arrival behind an
existing in-flight call for an arbitrary time, and a follower's own clock
arguably should not start until it becomes an owner. Proposed resolution: the
clock belongs to the *execution*, not the arrival — one deadline per inflight
`Call`, armed by the owner, shared by followers. Needs review by someone who
knows the claim machinery better than a reader of it does.

### 9.2 Interaction with the fast path and placement churn

`driveCtx` is cancelled on placement churn, and `driveActivity` deliberately
skips escalation when the claim is still live. A timeout deadline armed under the
fast path must not be cancelled by churn merely because the drive goroutine's
context was. The deadline should hang off the inflight `Call`, not `driveCtx` —
but I have not traced every path that can detach a publish watcher, and this is
the most likely place for the implementation to be subtly wrong.

### 9.3 Capability advertisement across a rolling upgrade

Should a new SDK refuse to schedule a timeout against a daprd that cannot
enforce it, or accept silent non-enforcement for the upgrade window? Refusing is
safer and noisier; accepting matches the precedent set by the external-event
proposal. Leaning accept-and-document, but this should be an explicit maintainer
decision rather than an implementation detail.

### 9.4 Should a schedule-to-close expiry be observable as distinct from a failure?

Right now it produces a terminal `TaskFailed` with a distinguishing `errorType`.
An alternative is a dedicated `TaskTimedOut` event, which would make history
inspection and tooling trivially clearer. Rejected above on history-size grounds
following the external-event proposal's own reasoning, but a maintainer may weigh
observability higher than I have.

### 9.5 Child workflows

`CallChildWorkflow` has the identical gap and the identical `TimerOriginChildWorkflowRetry`
machinery. The design transfers almost verbatim. Deliberately out of scope to
keep this reviewable, but the proposal should say the shape is intended to
generalize so the API is not designed into a corner.

---

## 10. Implementation plan

### Phase 1 — `scheduleToCloseTimeout` (SDK-only)

**Scope**
- `TimerOriginActivityTimeout` added to the `origin` oneof on `CreateTimerAction`
  and `TimerCreatedEvent` in `durabletask-protobuf`.
- Orchestrator-side race in `durabletask-go/task` alongside
  `internalScheduleTaskWithRetries`.
- Go and Python surfaces.
- Metrics.

**Acceptance criteria**
- An activity exceeding `scheduleToCloseTimeout` fails terminally with a
  distinguishable error type, in bounded wall-clock time.
- Replay of the resulting history produces identical actions on a cold worker.
- A completion arriving after the timer fired is dropped and does not appear in
  history.

**Deliberately excluded:** any `dapr/dapr` change. This phase ships against
today's runtime and is independently reviewable — the same sequencing argument
the delegated-identity proposal makes for its phase 1.

### Phase 2 — `startToCloseTimeout` (runtime)

**Scope**
- `startToCloseTimeout` on `ScheduleTaskAction` and `TaskScheduledEvent`.
- Deadline armed on the inflight `Call` in
  `dapr/pkg/actors/targets/workflow/activity`, synthesized `TaskFailed` through
  `publishResult`.
- Feature gate `WorkflowActivityTimeouts`.
- `activityDurationWarnAfter` report-only observation knob.
- Go and Python surfaces; .NET and Java to follow.

**Acceptance criteria**
- A deliberately wedged activity (`select {}` / `time.sleep(3600)`) fails within
  the configured bound and retries per policy.
- The orphaned body's eventual completion is dropped by dedup, verified by
  inspecting stored history, not just by observing workflow output.
- No wall-clock read is introduced on any orchestrator path (enforced by review
  plus the replay test in §11.3).
- With the gate off, a timeout field is rejected at schedule time with an
  actionable error.
- Absent timeouts produce byte-identical history to the pre-change build.

### Phase 3 — cancellation propagation and breadth

**Scope**
- `cancelActivityRequest` `WorkItem` variant and per-SDK context cancellation
  (§4.5).
- .NET, Java, JavaScript surfaces.
- Child workflow timeouts (§9.5).
- Documented state-store checkpointing pattern as the heartbeat replacement
  (§7).

---

## 11. Testing strategy

### 11.1 The wedged-activity test

An activity that blocks forever, with `startToCloseTimeout: 2s`. Assert the
workflow completes; assert history contains `TaskFailed` with the timeout error
type; assert the retry ran. This is the test the whole proposal exists for and
it should be an integration test against a real daprd, not a unit test with a
fake backend.

### 11.2 The late-completion test

Same setup, but the activity unblocks after the timeout. Assert the real
`TaskCompleted` is **not** present in stored history, and that the workflow
outcome is identical whether or not it arrived. This is the test that proves the
dedup reliance in §4.3 is real rather than assumed, and it should read the raw
stored history rather than trusting the workflow's return value.

### 11.3 Replay determinism

Replay a history containing a timeout-induced `TaskFailed` on a fresh worker,
with the clock set arbitrarily, and assert identical emitted actions. Then replay
one containing a `TimerFired` from a schedule-to-close expiry and assert the
same. If either is sensitive to wall-clock time, the design is wrong and this
test is where that surfaces.

### 11.4 Composition matrix

`startToClose` × `scheduleToClose` × `RetryPolicy(MaxAttempts, RetryTimeout)`,
including: start-to-close firing on every attempt until max attempts;
schedule-to-close firing mid-retry-delay; `Handle` predicate rejecting the
timeout error type; `startToClose > scheduleToClose` rejected at schedule time.

### 11.5 Crash and churn

Kill the host mid-attempt and assert the janitor re-dispatch arms a fresh
deadline. Force placement churn and assert a live claim's deadline is not
cancelled with `driveCtx` (§9.2).

### 11.6 Regression

The full existing workflow suite with no timeouts set, asserting unchanged
behaviour and unchanged history bytes. Given how much of `dapr/dapr`'s workflow
test suite is chaos and race regression tests, this is the cheapest insurance in
the plan.

---

## 12. Observability

New metrics:

- `dapr_workflow_activity_timeouts_total{activity, kind}` — `kind` is
  `start_to_close` | `schedule_to_close`
- `dapr_workflow_activity_orphaned_total{activity}` — timed-out bodies still
  running; the number that tells you how much work is being wasted
- `dapr_workflow_activity_late_completions_total{activity}` — orphans that
  eventually finished and were dropped by dedup
- `dapr_workflow_activity_execution_duration_seconds{activity}` — histogram, the
  input to setting timeouts in the first place, and the thing
  `activityDurationWarnAfter` reports against

The number to watch is the ratio of `timeouts_total` to `late_completions_total`.
Late completions close to timeouts means the timeout is merely too tight and the
work was fine; late completions near zero means bodies really are wedging and
never returning, which is a different bug in a different place.

---

## 13. What this does NOT fix

Stated plainly, because the residual risk is what makes the rest credible.

1. **The orphaned body keeps running.** Phase 1 and 2 do not stop it. It holds
   its connections, its memory, and any external lock until it returns on its
   own. A timeout makes the *workflow* recover; it does not make the *worker*
   recover.

2. **Timeouts increase concurrent duplicate execution.** Before this change, two
   live copies of an activity body required a host loss. After it, a
   retriable timeout produces them on a healthy host, on purpose. Activity
   idempotency moves from "load-bearing after a crash" to "load-bearing in normal
   operation." Anyone enabling a timeout on a non-idempotent activity is making
   their reliability worse, and the documentation must say so in those words.

3. **A slow activity and a wedged activity remain indistinguishable.** Without
   heartbeat (§7), the only discriminator is elapsed time. An activity whose
   legitimate duration spans two orders of magnitude must set its timeout at the
   tail, and a wedge inside that range goes undetected until the tail. This is
   the specific case that would justify revisiting heartbeat.

4. **The per-attempt clock does not survive a host loss.** The deadline is
   in-process (§4.3). A host dying at minute nine of a ten-minute budget yields a
   replacement attempt with a fresh ten minutes. `scheduleToClose` is the only
   durable bound, and it is the only thing standing between a flapping host and
   an unbounded total.

5. **No enforcement during a rolling upgrade.** A new SDK against an old daprd
   sets a field nobody reads (§6, §9.3). The workflow looks configured and is
   not.

6. **Nothing here bounds the orchestrator.** A workflow that loops forever
   scheduling bounded activities is still a workflow that loops forever.
   Workflow-level timeouts are a separate proposal.

7. **The timeout must still be chosen by a human.** The default is infinite
   (§6), deliberately, which means every activity in every existing codebase
   remains unbounded until someone edits it. This proposal supplies a control;
   it does not supply safety. The `activityDurationWarnAfter` knob exists
   precisely because the gap between "control exists" and "control is set" is
   where this feature will actually fail in production.

---

## 14. Success criteria

1. An activity that hangs indefinitely causes its workflow to fail or retry
   within a bound the author specified, rather than never.
2. That bound is enforced without the orchestrator reading a wall clock, proven
   by a replay test.
3. A late completion from a timed-out attempt cannot corrupt workflow history,
   proven by inspecting raw stored history.
4. Workflows with no timeouts configured produce byte-identical history to the
   pre-change build.
5. An operator can discover their real activity duration distribution before
   setting any timeout, and does not need to guess.

---

## Appendix A — the interim pattern

Until this ships, the timeout can be built in workflow code today, using only
primitives that exist. It is worth documenting honestly, both because people need
it and because it demonstrates the gap is real enough to be worked around:

```python
act = ctx.call_activity(slow_thing, input=payload)
deadline = ctx.create_timer(timedelta(minutes=10))
winner = yield when_any([act, deadline])

if winner is deadline:
    # The activity is still running. Nothing stops it. Its eventual
    # result will resolve `act`, which nothing is awaiting any more.
    raise TimeoutError("slow_thing exceeded 10m")
```

What it costs, relative to the proposal:

- The activity is orphaned with no engine awareness at all — the actor keeps its
  inflight claim and its engine registration, and no metric counts it.
- The retry interaction must be hand-built; `RetryPolicy` cannot see the timeout
  because the timeout is not a task failure.
- Every SDK expresses it slightly differently, and `when_any` semantics against a
  cancelled branch are the kind of thing that differs between languages in ways
  nobody notices until production.
- It bounds the wait from the orchestrator's side only. If the orchestrator's own
  host recycles, the recovered instance re-derives the timer from history
  correctly, but the abandoned activity is now abandoned by a process that never
  knew about it.

It is a correct workaround for the common case and it is what I would tell
someone to do this week. It is not a substitute for the engine knowing.
