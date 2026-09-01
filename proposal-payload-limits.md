# Proposal: Workflow Payload Offload and History Growth Signals

**Status:** Draft
**Target repo:** `dapr/proposals`
**Affects:** `dapr/dapr`, `dapr/durabletask-go`, `dapr/durabletask-protobuf`, SDKs, docs
**Author:** Allen Sanborn
**Date:** 2026-09

---

## 1. Abstract

Dapr Workflow persists every activity input and output into an event-sourced history, and the accumulated history must fit inside one gRPC message on the `GetWorkItems` stream between the sidecar and the SDK worker. That message is bounded by `--max-body-size`, default `4Mi`. The consequence is a hard ceiling that is a property of the *whole workflow*, not of any single payload, and that a workflow crosses gradually rather than hitting all at once.

Research for this proposal found that **most of the diagnostic half of this gap has already shipped**, in 1.17.7 and 1.17.0 respectively, and the standing gap analysis that motivated this work is out of date on that point. Dapr already detects the condition before the stream tears down, already stalls rather than failing, already emits a specific actionable message, already exports payload-pressure metrics as a ratio to the limit, and already has a retention policy and a purge API for reclaiming history. That materially shrinks what is left to build.

What remains is a narrower and sharper set of three things:

1. **The stall is recoverable only by an operator.** The remedy in the message is "increase daprd `--max-body-size` and restart to resume." A workflow cannot rescue itself, because nothing tells it that it is approaching the limit. Temporal solves exactly this with a graduated suggest/warn/error tier and an in-workflow `ContinueAsNewSuggested()` signal.
2. **There is no first-class large-payload mechanism.** The documented remedy is to restructure the workflow to pass references instead of inline data — the claim check pattern, described in prose and implemented by hand by every team that needs it. Temporal shipped a first-party version of this in 2026 (External Storage).
3. **A stalled workflow is not terminal, so the retention reaper never touches it.** Stalled instances accumulate.

This proposal addresses those in two phases with very different risk profiles, and recommends shipping only the first one soon.

---

## 2. Background

### 2.1 The actual limit, precisely

The gap analysis this proposal responds to says "a single workflow or activity dispatch is bounded by `--max-body-size`." That is close but imprecise in a way that matters for design, so it is worth restating from source.

**The flag.** `cmd/daprd/options/options.go:157-162` defines both the current and the legacy form:

```go
fs.IntVar(&maxRequestSizeMB, "dapr-http-max-request-size", runtime.DefaultMaxRequestBodySize>>20, "Max size of request body in MB")
fs.MarkDeprecated("dapr-http-max-request-size", "use '--max-body-size 4Mi'")
fs.StringVar(&maxBodySize, "max-body-size", "4Mi", "Max size of request body for the Dapr HTTP and gRPC servers, as a resource quantity")
```

`--max-body-size` takes a resource quantity, defaults to `4Mi`, and takes priority over the deprecated `--dapr-http-max-request-size` (`options.go:216-231`). The constant is `DefaultMaxRequestBodySize = 4 << 20` at `pkg/runtime/config.go:61-63`. The flag exists unchanged from at least v1.14.4 through v1.18.3 — nothing was renamed and the default did not move. The Kubernetes annotations are `dapr.io/max-body-size` and the legacy `dapr.io/http-max-request-size` (`pkg/injector/patcher/sidecar.go:98-101`), both unset by default.

**It is one knob for both protocols.** There is no separate gRPC message-size flag. The single value is fanned out to `grpcGo.MaxRecvMsgSize` and `MaxSendMsgSize` on both the API and internal gRPC servers (`pkg/api/grpc/server.go:359-360`), to `MaxCallSendMsgSize`/`MaxCallRecvMsgSize` on the app channel (`pkg/channel/grpc/grpc_channel.go:167-168`), to service invocation, the gRPC proxy, actor invocation, and to `maxResponseBodySize` on the HTTP channel. So it is simultaneously an HTTP body limit and a symmetric gRPC send/receive limit. The one deliberate exception is the Scheduler leg, which uses `math.MaxInt32` (`pkg/scheduler/server/server.go:240-241`).

**It does govern workflow dispatch.** The durabletask `TaskHubSidecarService` is registered on the daprd API gRPC server itself (`pkg/api/grpc/server.go:249-254`), which is the server constructed with those message-size options. The same value is threaded explicitly into the workflow engine (`pkg/runtime/wfengine/wfengine.go:89-92`, "MaxRequestBodySize is the gRPC server max message size in bytes") and down into the orchestrator actor (`pkg/actors/targets/workflow/orchestrator/factory.go:97`).

**But the check is cumulative, not per-dispatch.** This is the correction. `pkg/actors/targets/workflow/orchestrator/payloadsize.go` sums `proto.Size` over `IncomingHistory` + `History` + `Inbox` + folded completions and compares against 95% of the limit:

```go
payloadStallNumerator   = 95
payloadStallDenominator = 100
```

So the quantity under the ceiling is the **accumulated history of the instance**, not the size of one input. A workflow with two hundred 20 KiB activity results is as dead as a workflow with one 4 MiB result. A separate `activityPayloadOversize` applies the same 95% threshold to a single outbound `ActivityRequest`.

### 2.2 What Dapr already ships

This is the section that changes the shape of the proposal, so it is deliberately detailed.

**A pre-dispatch guard that stalls instead of tearing down (v1.17.7+).** `payloadsize.go` produces these messages verbatim:

> `Workflow payload size %d bytes exceeds %d%% of max gRPC body size %d bytes; increase daprd --max-body-size and restart to resume`

> `activity '%s::%d' payload %d bytes exceeds %d%% of max gRPC body size %d bytes; increase daprd --max-body-size and restart to resume`

surfaced as `protos.StalledReason_PAYLOAD_SIZE_EXCEEDED` (`pkg/actors/targets/workflow/orchestrator/run.go:565-567`). The offending workflow is stalled, its work item is never sent, the stream stays open, other workflows keep dispatching, and the stall is durable — re-loading re-runs the same pre-check. Setting `--max-body-size` to a non-positive value disables the guard entirely.

Version bisect on the raw file: 404 at v1.17.0/.1/.3/.5, present from **v1.17.7** onward and in all of 1.18. Runtimes older than 1.17.7 fail hard on the stream with `ResourceExhausted`.

**Metrics.** `runtime/workflow/payload/size_ratio` and `runtime/workflow/activity/payload/size_ratio` record payload-to-limit *ratio* with buckets up to 0.1, …, 0.95, 0.99, 1.0, 1.5, 2.0 (`pkg/diagnostics/workflow_monitoring.go:180-181, 301`). `(0.95, 1.0]` means stalled. Payload pressure is therefore already observable before it becomes an outage.

**Documentation.** There is a `## Limitations` → `### Payload size` section on [workflow-features-concepts](https://docs.dapr.io/developing-applications/building-blocks/workflow/workflow-features-concepts/) and a dedicated [Workflow payload size](https://docs.dapr.io/developing-applications/building-blocks/workflow/workflow-payload-size/) page explaining the 95% budget, the 5% headroom for `WorkflowStarted` injection and gRPC framing, and three remediations: raise the limit, force-purge, or *"restructure the workflow to avoid carrying large payloads across activities, for example by passing references (object store URLs, state-store keys) instead of inline data."* The claim check pattern, recommended in prose.

**Purge.** `POST /v1.0/workflows/dapr/<instanceId>/purge`, deleting history and metadata, plus recursive child cleanup and Scheduler reminder deletion. Preconditions: *"Only `COMPLETED`, `FAILED`, or `TERMINATED` workflows can be purged."* Present in all five SDKs (`PurgeInstanceAsync`, `purge_workflow`, `purgeWorkflow`, `PurgeWorkflowState`, `purgeWorkflow`).

**Automatic retention (v1.17.0).** A [Workflow History Retention Policy](https://docs.dapr.io/developing-applications/building-blocks/workflow/workflow-history-retention-policy/) with per-terminal-state TTLs:

```yaml
spec:
  workflow:
    stateRetentionPolicy:
      anyTerminal: "360h"
      completed: "1m"
      failed: "720h"
```

Default is indefinite retention. The policy *"only applies to workflows that newly reach a configured terminal state after the policy is in effect"*; backfill is `dapr workflow purge --all-older-than`.

**ContinueAsNew in all five SDKs**, documented under "eternal workflows" and the Monitor pattern, with the explicit statement that it *"truncates the existing history, replacing it with a new history."* The applier builds an entirely new state with a synthetic `ExecutionStartedEvent` and a fresh execution ID and drops the old history array wholesale (`dapr/durabletask-go` `backend/runtimestate/applier.go:110-147`).

**An anti-OOM bound.** `maxStateEntries = 1_000_000` (`pkg/runtime/wfengine/state/state.go:57-61`), enforced against a tampered state store. Not a product limit; nobody reaches it, because the byte-based 95% stall fires orders of magnitude earlier.

### 2.3 What is genuinely missing

**No size guard whatsoever in the engine.** `dapr/durabletask-go` is entirely permissive. Activity results are `json.Marshal`ed (`task/executor.go:218-226`), wrapped in a `google.protobuf.StringValue`, and appended to history verbatim — no compression, no content addressing, no offload, no cap. An exhaustive case-insensitive grep for `maxsize|max_size|maxpayload|truncat|size limit|maxevent` across the repo returns zero non-test hits. Every guard lives in the dapr host and arrives late.

**No graduated tiers and no in-workflow signal.** Dapr has exactly one threshold, at 95%, and crossing it is a cliff. Temporal has three:

| Tier | Temporal key | Default |
| --- | --- | --- |
| Suggest CaN (bytes) | `limit.historySize.suggestContinueAsNew` | 4 MiB |
| Suggest CaN (events) | `limit.historyCount.suggestContinueAsNew` | 4,096 |
| Warn | `limit.historySize.warn` / `limit.historyCount.warn` | 10 MiB / 10,240 |
| Error | `limit.historySize.error` / `limit.historyCount.error` | 50 MiB / 51,200 |

(from `temporalio/temporal` `common/dynamicconfig/constants.go`)

The suggest tier is surfaced *into the workflow* as `workflow.GetInfo(ctx).GetContinueAsNewSuggested()` (Go, since SDK v1.25.0 / server 1.20+), `isContinueAsNewSuggested()` (Java), `is_continue_as_new_suggested()` (Python), `continueAsNewSuggested` (TypeScript), with a companion `GetContinueAsNewSuggestedReasons()` returning `HistorySizeTooLarge` / `TooManyHistoryEvents` / `TooManyUpdates`. Dapr has no equivalent at any layer — verified absent from `durabletask-go` and from the `WorkflowRequest` proto.

Note the calibration: Temporal's suggest tier sits an order of magnitude below its termination cap. Dapr's only signal sits at 95% of its only limit.

**No first-party claim check.** Temporal shipped [External Storage](https://docs.temporal.io/external-storage) — first-party S3 and GCS drivers for Go, Python, and TypeScript, sitting at the end of the data-conversion pipeline after the payload converter and codec, offloading at a default threshold of **256 KiB**. Its predecessor and origin is DataDog's `temporal-large-payload-codec`. Java is not on the first-party list. Dapr has nothing.

**Inconsistent ContinueAsNew semantics across SDKs.** The unprocessed-events behavior has three names and two defaults:

| SDK | Parameter | Default |
| --- | --- | --- |
| .NET | `preserveUnprocessedEvents` | `true` |
| Java | `preserveUnprocessedEvents` | `true` |
| Python | `save_events` | `False` |
| Go | `WithKeepUnprocessedEvents()` option | opt-in (off) |
| JS | `saveEvents` | required positional |

Porting a workflow between .NET and Python silently changes whether buffered external events survive a restart. That is a correctness bug waiting to happen and it is independent of everything else in this proposal.

**Stalled instances are never reclaimed.** A stalled workflow is not `COMPLETED`, `FAILED`, or `TERMINATED`, so purge refuses it and `stateRetentionPolicy` never reaps it. The documented remedy is force-purge, which the CLI itself warns *"will otherwise corrupt the workflow state machine."* *(This specific interaction is an inference from the two documented preconditions; I did not find a doc or test asserting it, so treat it as **unverified** until confirmed.)*

**No prior art in `dapr/proposals`.** All 25 proposal files were enumerated and grepped for `claim check`, `payload size`, `large payload`, `history retention`, `history purge`, `external storage`, `blob storage`. Zero hits. Both the payload-size stall and the retention policy shipped without a proposal document. Workflow-adjacent proposals that do exist: `20250320-RS-multi-app-workflows.md` (the origin of `PropagatedHistory`, one of the three terms in the size budget), `20251028-BRS-workflow-versioning.md`, `20250404-RS-workflow-rerun-from-activity.md`, `20260318-RS-workflow-external-event-timer-tracking.md`.

---

## 3. Goals and non-goals

### Goals

- Give a workflow an in-band signal that its history is approaching the dispatch limit, early enough to act on, so recovery does not require an operator.
- Make the existing stall message attribute the pressure to a specific cause rather than reporting only a total.
- Provide an optional, opt-in payload offload that transparently moves oversized activity inputs and outputs to a configured store and rehydrates them before dispatch.
- Make offload lifecycle a consequence of the history lifecycle Dapr already manages, not a new independent retention problem.
- Guarantee that offload cannot silently downgrade confidentiality relative to an encrypted actor state store.
- Keep application and activity code unchanged for the offload path.
- Remain additive and feature-gated throughout.

### Non-goals

- **Raising or removing the 4 MiB limit.** It is a sane default protecting a shared gRPC server and this proposal does not touch it.
- **Making blobs-in-workflows a good idea.** Passing references remains the better pattern. §11 argues this explicitly.
- **A general-purpose large-message mechanism for pub/sub, bindings, or service invocation.** Those share the same flag and the same pain, and deserve their own treatment. This proposal is workflow-scoped.
- **Bounding event count.** Byte pressure is the observed failure mode; event-count pressure is a separate, unmeasured concern (§9.3).
- **Compressing history.** Discussed and rejected in §10.
- **Solving key-free decode for tooling.** That is the payload-codec gap; §8.4 explains how these two must share an interception point without colliding.

---

## 4. Design, phase 1 — make the limit visible before it bites

Phase 1 adds no component, no store, no new failure mode, and no new bytes anywhere. It is a signal and a message.

### 4.1 A continue-as-new suggestion

`payloadsize.go` already computes the exact number this needs. The change is to compute it at every dispatch rather than only when it crosses 95%, and to carry the result to the SDK.

Proposed thresholds, expressed as fractions of the `--max-body-size` budget:

| Tier | Fraction | Effect |
| --- | --- | --- |
| Suggest | 0.50 | `ContinueAsNewSuggested = true` on the work item; `HISTORY_SIZE_TOO_LARGE` reason |
| Warn | 0.80 | Above, plus a runtime `WARN` log naming the instance ID and the top contributors |
| Stall | 0.95 | Existing behavior, unchanged |

Both fractions are configurable under `spec.workflow` in Configuration, alongside `stateRetentionPolicy`. The 0.50 default is chosen so a workflow that acts on the suggestion has roughly as much room again as it has already consumed — it is the same order-of-magnitude margin Temporal picked, expressed against a much smaller absolute budget.

**Wire change.** A field on `WorkflowRequest` in `dapr/durabletask-protobuf`:

```proto
message ContinueAsNewSuggestion {
  bool suggested = 1;
  repeated ContinueAsNewReason reasons = 2;
  double history_size_ratio = 3;   // 0.0 – 1.0 against the dispatch budget
}

enum ContinueAsNewReason {
  CONTINUE_AS_NEW_REASON_UNSPECIFIED = 0;
  CONTINUE_AS_NEW_REASON_HISTORY_SIZE_TOO_LARGE = 1;
}
```

`reasons` is a repeated enum rather than a scalar specifically so an event-count tier (§9.3) can be added later without a breaking change.

**SDK surface**, matching the naming each SDK already uses for `ContinueAsNew`:

```csharp
if (context.ContinueAsNewSuggested) { context.ContinueAsNew(Checkpoint(state)); return; }
```

```python
if ctx.continue_as_new_suggested:
    ctx.continue_as_new(checkpoint(state), save_events=True)
    return
```

Go: `ctx.ContinueAsNewSuggested()`. Java: `ctx.isContinueAsNewSuggested()`. JS: `ctx.continueAsNewSuggested`.

**Determinism.** The value is derived from the sidecar's view of the current history, not from workflow-visible state, and it can differ between the original execution and a replay of the same history — a warm actor and a cold actor may disagree at the margin. Reading it is therefore a **non-deterministic operation** in exactly the way `ctx.Now()` would be if it were not recorded, and if a workflow branches on it, replay can take the other branch.

The resolution is the one durable-task already uses for every other non-deterministic input: **the value must be recorded into history at the point it is read**, so replay returns the recorded value rather than recomputing it. Concretely, the suggestion is captured on the work item and pinned for the duration of that orchestrator turn, and the branch taken becomes a matter of history rather than of live measurement. Temporal's own documentation warns that the value *"may change throughout the life of the workflow"*, which is the same hazard stated from the other direction.

This is the single most important correctness detail in phase 1 and it must have a dedicated replay test (§13.1). Getting it wrong produces non-deterministic replay in the exact code path meant to keep workflows healthy.

### 4.2 Attribute the pressure

Today the stall message reports a total. An operator receiving it knows the workflow is too big and knows nothing about why. The same sum already walks every event, so the breakdown is free:

> `Workflow 'order-4471' payload size 4,057,336 bytes exceeds 95% of max gRPC body size 4,194,304 bytes. Largest contributors: activity 'FetchInvoicePdf' output 2,105,344 bytes (52%, 1 occurrence); activity 'ScoreLineItem' output 918,272 bytes total (23%, 214 occurrences, 4,291 bytes each). Increase daprd --max-body-size and restart to resume, or see <link>.`

Those two shapes are the two distinct diseases, and they have different cures. One big payload is a claim-check problem (§5). Many small payloads is a continue-as-new or child-workflow problem (§4.1). A message that does not distinguish them sends the reader to the wrong remedy, and "raise the limit and restart" is the wrong remedy for both.

Top-3 contributors, grouped by activity name, is enough. This is a strictly-better error string on a code path that already has the data in hand.

### 4.3 Reclaiming stalled instances

Pending confirmation of the interaction noted in §2.3, either:

- add `stalled` as an eligible disposition in `stateRetentionPolicy`, on the grounds that a workflow that has been stalled for a configured duration is not going to un-stall on its own; or
- document loudly that stalled instances are exempt from retention and must be force-purged, and expose their count as a metric so the accumulation is visible.

The metric is worth adding either way: `runtime/workflow/stalled_instances{reason}` as a gauge. A slowly-climbing count of `PAYLOAD_SIZE_EXCEEDED` stalls is a leading indicator that a whole class of workflow is mis-shaped, and it is currently invisible.

---

## 5. Design, phase 2 — payload offload

Phase 2 is optional, opt-in, off by default, and considerably riskier. It is presented in full because the design questions deserve real answers, and §12 recommends against shipping it first.

### 5.1 Composition, not new infrastructure

Dapr already has both halves. A claim check needs put, get, and delete against durable storage. Dapr has `state` components with exactly that shape plus TTL, and `bindings` with `create`/`get`/`delete` operations against S3, Azure Blob, and GCS.

So: **no new component type.** The offload target is a reference to an existing configured component, declared in Configuration next to the retention policy it shares a lifecycle with:

```yaml
apiVersion: dapr.io/v1alpha1
kind: Configuration
metadata:
  name: appconfig
spec:
  features:
    - name: WorkflowPayloadOffload
      enabled: true
  workflow:
    payloadOffload:
      component: wf-payload-store    # an existing state or binding component
      threshold: "256Ki"             # offload payloads at or above this size
      keyPrefix: "dapr-wf-payloads"  # must not be shared with any other writer
```

The `256Ki` default is taken directly from Temporal's External Storage default. Offloading well below the limit rather than at it is deliberate: the point is that nobody arrives at the cliff, not that the cliff is survivable.

Not every component qualifies. A state component must support TTL and deletion; a binding must support `create`, `get`, and `delete`. Anything else is **rejected at Configuration load time with an explicit error**, in the same spirit as rejecting `onBehalfOf` on a Kafka binding. Silently ignoring an unusable offload target would mean the feature appears enabled and does nothing until the day a large payload arrives.

### 5.2 Where the interception happens

**In the sidecar, not the SDK.** This is the load-bearing architectural choice and it diverges from Temporal.

Temporal put External Storage in the SDK because it had no choice: the server never sees plaintext, since the whole point of the Data Converter is that encryption happens client-side. The cost is per-language implementations and uneven coverage — Go, Python, and TypeScript have it; Java does not.

Dapr's sidecar already sees plaintext. It is the component that performs state-store AES-GCM encryption before data leaves the process, and it is where `payloadsize.go` already measures payloads. Putting offload in daprd means one implementation covering all five SDKs on the day it ships, and it means the offload decision is made at the same place the size is already computed.

The evidence that per-SDK implementation goes wrong here is already in the repo: `ContinueAsNew`'s unprocessed-events default differs between .NET and Python for no reason anyone intended (§2.3). Five implementations of a claim check would drift the same way, and drift in this one produces unreadable histories rather than surprising event handling.

Concretely, the hook sits between the orchestrator actor building a history event and that event being handed to the state layer, and symmetrically on the load path before `LoadWorkflowState` returns to the dispatcher.

### 5.3 The pointer

The offloaded payload is replaced in the `StringValue` input/result field by a self-describing envelope:

```json
{
  "__daprPayloadRef": {
    "v": 1,
    "component": "wf-payload-store",
    "key": "dapr-wf-payloads/order-4471/e6f1c8/00000214",
    "size": 2105344,
    "sha256": "9f2c…",
    "encoding": "identity",
    "crypto": { "component": "wf-crypto", "keyName": "payload-key" }
  }
}
```

Every field is load-bearing. `component` means a config change that repoints the store does not orphan existing histories — the envelope names the store that actually holds the bytes. `size` means the size guard can account for offloaded payloads without fetching them. `sha256` makes silent corruption or a key collision detectable. `crypto` records which key encrypted the blob, mirroring how state-store encryption already appends `secretKeyRef.name` to the state key so rotation works.

The key is `<keyPrefix>/<instanceID>/<executionID>/<eventSequence>`. The instance-ID segment is what makes GC tractable (§6); the execution-ID segment is what makes ContinueAsNew tractable (§6.3).

An application could in principle write a JSON object with a `__daprPayloadRef` key and have it rehydrated as if it were a pointer. Rehydration therefore only applies to envelopes daprd itself wrote, distinguished by an internal marker on the history event rather than by inspecting the JSON. Sniffing user payloads for a magic key is a confused-deputy bug, not a serialization convenience.

### 5.4 Write ordering

The blob is written **before** the history event that references it is committed, always. If the history commit then fails, the result is an orphaned blob, which is inert and reclaimable (§6.4). The reverse ordering produces a committed history event pointing at nothing, which is unrecoverable data loss on a durable log.

This asymmetry — orphan over dangle — is the same trade every write-ahead design makes, and it is why §6.4's sweeper is a requirement and not a nicety.

---

## 6. Lifecycle and garbage collection

This is the part that kills claim-check designs, and it is worth being direct about why: an offloaded payload outlives the workflow unless something deletes it, workflows have no bounded lifetime, and every obvious deletion trigger is wrong.

### 6.1 What does not work

**TTL on the blob.** A TTL shorter than the workflow's life destroys replay. A TTL longer than the workflow's life leaks, because the workflow's life is unbounded. There is no value that is correct, and the failure mode of guessing low is silent data loss on a durable log.

**Reference counting.** Replay re-reads the same events repeatedly and a crashed sidecar drops decrements. Counts drift toward either premature deletion or permanent leak, and only one of those is detectable.

**Deleting on activity completion.** Wrong by construction. Replay needs the input again.

### 6.2 What works: inherit the history's lifecycle

An offloaded payload is not an independent object. It is a displaced part of exactly one history event, belonging to exactly one instance, and it should be reclaimed by exactly the machinery that reclaims that instance's history.

Dapr acquired that machinery in v1.17. Purge deletes history and metadata; `stateRetentionPolicy` invokes purge automatically on terminal instances after a configured duration; the CLI backfills older instances. **Offload therefore adds no new retention concept at all.** It adds one step inside the existing purge operation: after deleting the history keys for instance `I`, delete everything under `<keyPrefix>/I/`.

This is only tractable because retention shipped first. A claim check proposed against Dapr 1.16 would have had to invent a reaper, and would have been correctly rejected for it. Proposed against 1.17+, the entire retention story is "it is already handled," and that is the strongest argument in favor of the design.

Two consequences follow and both belong in the docs in bold:

1. **Instances with offloaded payloads should not be retained indefinitely.** Default retention is indefinite; combined with offload that means an object store that only grows. Enabling `payloadOffload` without a `stateRetentionPolicy` should emit a startup warning.
2. **The operator must not put a lifecycle policy on the offload bucket.** An S3 lifecycle rule expiring objects after 90 days will silently delete payloads belonging to live workflows. Dapr owns deletion of that prefix; anything else deleting from it is a correctness hazard. This deserves its own callout, because reaching for a bucket lifecycle rule is the natural instinct of anyone who sees a growing bucket.

### 6.3 ContinueAsNew

CaN discards the old history wholesale — the applier builds a fresh state with a new execution ID and drops the previous history array. Every blob under the old execution ID becomes garbage at that moment, **except the new input**, which was the CaN result and is carried into the synthetic `ExecutionStartedEvent`.

So CaN's offload handling is: copy-forward the new input's blob under the new execution ID (or re-key it), then delete the old execution-ID prefix. The execution-ID segment in the key exists precisely to make this a prefix delete rather than a per-event bookkeeping exercise.

Note the pleasing interaction with phase 1: the suggestion mechanism drives workflows toward CaN, and CaN is the one operation that reclaims offloaded storage on a *live* workflow. A long-running instance that continues-as-new periodically bounds both its history and its blob footprint. One that never does bounds neither.

### 6.4 The sweeper

Purge is best-effort across two stores, and §5.4 deliberately prefers orphans to dangles. Orphans therefore exist and something must reclaim them.

A periodic sweeper lists blob prefixes under `keyPrefix`, checks whether the corresponding instance metadata exists, and deletes prefixes whose instance is gone. It runs on a long interval — hours, not minutes — and only deletes prefixes whose newest object is older than a configurable grace period comfortably longer than any plausible in-flight write.

Two hard constraints:

- **The grace period is not optional.** A newly-created blob whose history event has not yet committed looks exactly like an orphan. Deleting it races the write path and produces the dangle the ordering rule exists to prevent.
- **Listing is expensive on object stores.** This must be a scheduled maintenance operation with an explicit cost, not something running continuously. On a store where prefix listing is not cheap, the sweeper should be disable-able, accepting orphan accumulation as the lesser problem.

The sweeper is second-line cleanup. If it becomes the primary mechanism, purge integration is broken and the sweeper is masking it. Its deletion count is therefore a metric worth alerting on, not just observing.

---

## 7. Determinism and replay

### 7.1 The easy part

Rehydration happens in daprd before the work item is dispatched, so the SDK worker sees byte-identical inputs on the original execution and on every replay. Offload happens only on the *write* path, when a history event is first created; replay reads existing events and never re-offloads. Blobs are write-once and never mutated — keys include an event sequence and are never reused, so there is no update path to get wrong.

Given the blob exists, replay is deterministic by construction, and `sha256` in the envelope turns "given" into "verified."

### 7.2 The hard part: the blob is gone

This is the failure mode that must be designed rather than discovered, so here it is explicitly.

Causes, roughly in order of likelihood: an operator bucket lifecycle rule (§6.2); the sweeper's grace period set too low; a store repointed in config while old envelopes name the old component; credential expiry or a network partition to the store; genuine data loss.

Only the last is unrecoverable. Every other cause is an operator-side condition that can be fixed and retried — a restored object, a corrected credential, a healed partition. That observation determines the design:

| Option | Verdict |
| --- | --- |
| Fail the activity, retry per policy | Wrong. Retrying a missing blob will not find it, and the retry budget expires into a failed workflow. |
| Fail the workflow | Wrong. Irreversible, and irreversible is the wrong shape for a recoverable operator condition. |
| Return a null/empty payload | Badly wrong. Silent corruption of a durable log; the workflow proceeds on data it did not receive. |
| **Stall the workflow** | **Correct.** |

The recommendation is **stall**, reusing the machinery `PAYLOAD_SIZE_EXCEEDED` already established, with a new `StalledReason_PAYLOAD_UNAVAILABLE`:

> `Workflow 'order-4471' cannot be dispatched: offloaded payload 'dapr-wf-payloads/order-4471/e6f1c8/00000214' (2,105,344 bytes) is not retrievable from component 'wf-payload-store': NoSuchKey. The workflow is stalled and will resume when the payload is available. See <link>.`

A stall is durable, visible, non-destructive, and reversible the moment the underlying condition is fixed — the next dispatch attempt simply succeeds. It also means Dapr never has to decide whether missing data is fatal, which is not Dapr's decision to make.

Integrity failure — the blob is present but its `sha256` does not match — is a **different** condition and must not be conflated. Retrying will not help and the data is wrong rather than absent. That is a hard failure with a distinct message, because proceeding on payload the runtime knows is corrupt is worse than any of the alternatives.

### 7.3 Partial history

A workflow can have some events offloaded and some inline, and the offload threshold can change between executions. Nothing here depends on uniformity: each event is self-describing, and a history mixing both forms replays correctly. Lowering the threshold does not retroactively offload old events; raising it does not rehydrate them back into history. Both are fine, and both should be stated in the docs so nobody expects a migration.

---

## 8. Encryption

Offload can silently downgrade confidentiality, and preventing that is a requirement rather than a consideration.

### 8.1 The exposure

Dapr encrypts state-store data client-side: AES-GCM with 128/192/256-bit keys, performed by the sidecar before data leaves the process, keys fetched from a secret store rather than sitting in component metadata, with primary/secondary keys for rotation. Because workflow history persists through the actor state store, enabling encryption on that store encrypts workflow history at rest.

Offload moves the largest and most sensitive payloads *out of that store*. If the destination is an object-storage **binding**, there is no encryption at all — bindings have no equivalent of the state store's automatic AES-GCM path. The naive design therefore takes the payloads most worth protecting and writes them in plaintext to a bucket, while the operator's configuration still says encryption is on.

That is unacceptable as a default and unacceptable as an opt-in that requires reading the docs to discover.

### 8.2 Fail closed

**If the actor state store backing workflow has `primaryEncryptionKey` configured and the configured offload target does not provide equivalent protection, daprd refuses to start with `WorkflowPayloadOffload` enabled.** Startup failure, with a message naming both components and the three ways to resolve it.

No silent downgrade, no warning-and-continue. A warning at startup is read once, by whoever ran the deploy, and never again.

### 8.3 The three resolutions

**Target a state component (recommended).** The existing sidecar-side AES-GCM applies to the offloaded blob exactly as it applies to history. Offload becomes confidentiality-neutral by construction, and there is no new key management, no new rotation story, and nothing new to audit. This is why the design accepts state components as offload targets even though object storage is the more obvious fit — the encryption story is strictly better and it costs nothing to allow.

**Target a binding, with envelope encryption via the existing `crypto` building block.** daprd encrypts the payload through a configured crypto component before `create` and decrypts after `get`, recording the component and key name in the envelope's `crypto` field so rotation resolves the same way `secretKeyRef.name` already does for state. This is more moving parts and a genuinely new key-rotation surface, but it is the option that gets an operator's own KMS involved.

**Explicit acknowledgement.** `payloadOffload.acknowledgeUnencrypted: true`, required to start with an unprotected target while the state store is encrypted. Named to be uncomfortable to type and to be obvious in a config review.

### 8.4 What encryption does not cover, and the collision to avoid

Object keys embed instance IDs, and object listings expose sizes, counts, and timing. An observer with read access to the bucket learns which workflows ran, roughly how big their payloads were, and when — without decrypting anything. Encryption is confidentiality of contents, not of metadata, and moving payloads to a store with different access controls than the state store is itself a change in exposure. Access to the offload store should be scoped as tightly as access to the actor state store, and the docs should say so plainly.

**The collision.** The gap analysis motivating this work also argues for a per-payload codec hook — Dapr's answer to Temporal's Payload Codec, giving selective and pluggable payload protection with a key-free decode path for tooling. That hook and this offload hook want **the same position in the pipeline**: after serialization, before persistence.

Temporal ordered them explicitly — External Storage sits at the end of the conversion chain, *after* the payload converter and codec, so what gets offloaded is already-encoded bytes. Dapr should adopt the same order for the same reason: offloading ciphertext is safe, while encrypting-after-offload would mean the pointer envelope is encrypted and the payload is not.

Whichever of the two ships first should be built as a **pipeline stage with a defined position**, not as an inline special case in the orchestrator actor. If offload lands as a hardcoded branch, the codec proposal will have to unpick it, and the two mechanisms will fight over an interception point that only one of them can own.

A useful side effect worth stating: offload makes selective protection cheaper to reason about later, because an offloaded payload is a discrete addressable object with its own metadata, rather than a field inside a state entry encrypted all-or-nothing with the rest of the store.

---

## 9. History growth independent of payload size

Question 5 of the brief. The verified answer is that Dapr already has more here than the gap analysis credits, and the remaining gap is narrow but real.

### 9.1 Already present

ContinueAsNew in all five SDKs, documented as *"a great way to keep the workflow history size small"* and as the mechanism for eternal workflows; child-workflow fan-out documented as the pattern for thousands of tasks; the 95% stall as a backstop; the ratio metrics as an early indicator; purge and `stateRetentionPolicy` for reclamation. This is a real history-management story, not an absence.

### 9.2 The remaining gap is the signal, not the mechanism

The mechanism exists. What is missing is any way for a workflow to know it should use it. `ContinueAsNew` sitting in the SDK is only useful to a developer who anticipated the problem at design time; the suggestion in §4.1 is what makes it useful to one who did not.

This is why §4.1 is phase 1 and the claim check is phase 2. A workflow that continues-as-new when told to has a bounded history regardless of what it does with payloads. A workflow that never does will eventually stall whether or not offload exists — offload lowers the slope but does not bound the sum.

### 9.3 Event count: measure before proposing

Temporal limits both bytes and event count. Dapr limits only bytes, and the 1,000,000-entry cap is an anti-tampering bound rather than a product limit.

The honest position is that **there is no evidence a count limit is needed in Dapr**, because the byte-based stall fires at hundreds-to-low-thousands of events for typical event sizes — far below any count threshold worth setting. Temporal needs a count dimension partly because its per-payload limit is small and its history budget is large, giving it room to accumulate many events; Dapr's single 4 MiB budget forecloses that.

So: add an event-count dimension to the exported metrics, ship phase 1, and revisit only if production data shows histories with high event counts and low byte totals. The `reasons` field in §4.1 is a repeated enum specifically so `TOO_MANY_HISTORY_EVENTS` can be added without a wire break if that data ever appears. Proposing a count limit now would be designing against a hypothetical.

### 9.4 Align the ContinueAsNew defaults

Independent of everything else, the split in §2.3 should be fixed: .NET and Java preserve unprocessed events by default, Python and Go drop them. Changing a default is breaking, so the path is to document the divergence prominently now, deprecate the parameterless overloads that hide it, and require an explicit argument in a future major. Small, unglamorous, and it prevents a class of silent bug in ported workflows.

---

## 10. Alternatives considered

**Do nothing; the docs already say to pass references.** Genuinely defensible, and §11 concedes a large part of it. The counter is narrow: documentation does not help a team that discovers the constraint in production at 3 a.m., and it does not help a workflow already stalled with 4 MiB of committed history — restructuring to pass references does nothing for instances that already exist.

**Raise the default `--max-body-size`.** Buys one order of magnitude, moves the cliff without removing it, and increases the memory ceiling on a gRPC server shared by service invocation, actors, and the app channel. It also breaks the property that the default protects an unconfigured cluster from a single misbehaving workflow. Rejected.

**Compress history.** A real win for the "many small payloads" disease — JSON activity results compress well, often 5-10x, and this needs no new store, no lifecycle, and no GC. Tempting enough to name as the strongest alternative to phase 2. It fails for the "one huge payload" disease, since a 20 MiB PDF does not compress under 4 MiB, and it makes histories opaque to any tooling that reads the state store directly. Worth considering as an independent optimization; not a substitute for either phase here.

**Per-SDK offload, following Temporal.** Five implementations, guaranteed drift (§5.2), and slower coverage. The reason Temporal chose it does not apply to Dapr, whose sidecar already handles plaintext. Rejected.

**A dedicated `payloadstore` component type.** Cleaner interface, and lets a store advertise exactly the required capabilities rather than being validated against a subset of an existing contract. Rejected on cost: it requires new implementations for S3, Azure Blob, GCS, Redis, and so on, all of which already exist as bindings and state stores. Reuse first; introduce the type only if capability validation against existing contracts proves unworkable in practice.

**Offload everything, not just oversized payloads.** Uniform, and it removes the threshold as a tuning knob. Rejected: it turns every activity into two round trips including the overwhelming majority that are a few hundred bytes, and it makes the object store a hard dependency of every workflow rather than a safety net for large ones.

**Store the blob in the same actor state store, under a separate key.** Sidesteps the encryption problem entirely and inherits purge for free. It fails on the thing that motivates the proposal — the state store per-item limits are what several of the cited issues are about, and it does nothing for a payload that is large in absolute terms. Useful only as the degenerate case where the offload target happens to be the same component, which the design already permits.

---

## 11. What this does NOT fix

Stated plainly, because a claim check invites more optimism than it earns.

- **It does not make large payloads in workflows a good design.** Passing references remains better than offloading them, because a reference the application manages keeps the blob's lifecycle under the application's control and out of the durable log entirely. Offload is a safety net for teams that discover the constraint late, not a license to move blobs through orchestrations.
- **It does not bound history growth.** Offload lowers the slope. A workflow with 50,000 small activity results still stalls. Only ContinueAsNew, child workflows, or a shorter workflow bound the sum, which is why §4.1 matters more than §5.
- **It does not reduce peak sidecar memory much.** Rehydration means the full payload is in daprd's memory during dispatch regardless. What it changes is that cumulative memory goes from the sum of every payload in history to the size of the largest single one — a real improvement, but a different one from the one people will assume.
- **It does not reduce replay CPU time.** Replay still walks every event, and now some of them require a fetch.
- **It does not relax the determinism constraints.** No clock, no randomness, no I/O in orchestrator code. Unchanged.
- **It does not give tooling a key-free decode path.** If anything it makes history rendering harder: a console now needs credentials to both the state store and the offload store. That gap belongs to the codec proposal (§8.4).
- **It does not address stack-trace and failure-message leakage.** `TaskFailedEvent` carries `TaskFailureDetails`, not a payload field, and failure text is not offloaded, not encrypted by a codec, and not scrubbed. Temporal names this exposure explicitly; Dapr has it too and does not.
- **It does not help pub/sub, bindings, or service invocation**, which share the same flag and the same cliff.
- **It does not remove `--max-body-size` tuning.** It lowers how often you need to, and phase 1 makes the message tell you what to change.
- **It does not fix runtimes older than 1.17.7**, which have no stall guard and fail with `ResourceExhausted` on the stream.

---

## 12. Recommendation

The brief asks whether a cheap "warn better" phase delivers most of the value for almost none of the risk, and asks for an honest answer against the more ambitious design.

**The honest answer is that the warning already shipped, and the cheap high-value work is one step past it.**

Dapr 1.17.7 detects the condition, stalls instead of tearing down, prints an actionable message naming the flag, and exports payload-pressure ratios. The premise that the failure mode is "a confusing transport error" was true through 1.17.5 and is not true today. Repeating that recommendation would be proposing work already done.

What is still true is that the message's only remedy is operator-side. Every path out of a stall runs through a human raising a flag and restarting a sidecar, and the workflow itself is a passive participant in its own failure. That is the gap worth closing first, and §4 closes it with a boolean on a proto, a threshold comparison in a function that already computes the number, a better error string, and one field per SDK. No new component, no new store, no lifecycle, no GC, no encryption interaction, and one genuinely subtle correctness requirement — pinning the suggestion into history so replay stays deterministic (§4.1).

**Ship phase 1 alone.** It is small enough to review properly, it converts an operator page into a workflow-level self-heal, and it makes the mechanism Dapr already has usable by developers who did not anticipate needing it.

**Phase 2 should be a separate proposal, and it should be argued on the strength of the narrower claim it can actually support:** that a first-class claim check prevents the 4 MiB cliff from being a production incident for teams whose payloads are genuinely large and genuinely occasional. That claim is real, Temporal validated it by shipping External Storage after years of the same "pass references" advice, and Dapr can implement it better than Temporal did by putting it in the sidecar and covering five SDKs at once. It is also the half carrying all the lifecycle, replay-failure, and encryption risk, and it should not ride into review attached to a proposal that would otherwise be uncontroversial.

**And part of this gap is correctly solved by discipline.** The advice to pass pointers is not a workaround for a missing feature; it is the better architecture, and it stays the better architecture after offload ships. A workflow whose history holds identifiers replays fast, stores small, leaks nothing into the durable log, and needs no object store to be reachable years later. That is a strictly better position than one reached by offloading blobs transparently. Temporal's own default threshold of 256 KiB — offloading long before anything is at risk — is the same admission from the other direction: the mechanism exists so that nobody arrives at the limit, not so that arriving there becomes acceptable.

The runtime's job here is not to make blobs in workflows work well. It is to make the boundary visible early, name it precisely, and give the workflow a way to act before an operator has to. That is phase 1.

---

## 13. Testing strategy

### 13.1 Phase 1

- **Replay determinism (non-negotiable).** A workflow that branches on `ContinueAsNewSuggested` must take the same branch on replay as it did on first execution, including when the underlying ratio has changed between the two — cold actor versus warm actor, and across a sidecar restart. This is the test that catches §4.1's hazard, and it is the reason phase 1 is not entirely trivial.
- Threshold boundary tests at 0.499 / 0.501 / 0.799 / 0.801 / 0.949 / 0.951 of the budget.
- The existing stall behavior at 0.95 is unchanged, asserted against the existing integration suite (`tests/integration/suite/daprd/workflow/payloadsize/`).
- Attribution correctness: one large payload versus many small ones must produce different top-contributor breakdowns, with the counts and percentages right in both.
- Cross-SDK: the same workflow logic in all five SDKs observes the suggestion at the same point.
- With `--max-body-size <= 0`, the suggestion is never raised and no metric is recorded, matching the existing guard's behavior.

### 13.2 Phase 2

- Round-trip fidelity for payloads at the threshold minus one byte, exactly at the threshold, and far above, across every supported target type.
- Replay with the blob present, with it deleted (expect stall, not failure), with a `sha256` mismatch (expect hard failure, not stall), and with the store unreachable (expect stall, and expect recovery on the next dispatch once reachable).
- Purge deletes both history and the blob prefix, including recursively for child workflows.
- ContinueAsNew copies the new input forward and deletes the old execution prefix, verified by direct object-store listing.
- Crash between blob write and history commit leaves an orphan and no dangle; the sweeper reclaims the orphan only after the grace period, never before.
- **Encryption fail-closed:** daprd refuses to start with an encrypted actor state store and an unprotected offload target, and starts with each of the three resolutions in §8.3.
- **Raw-store inspection:** with a state target and encryption on, the offloaded object's raw bytes contain no plaintext from the payload.
- Mixed histories, and threshold changes between executions, replay correctly in both directions.
- Load-time rejection of an offload component lacking the required operations.

---

## 14. Observability

Phase 1:

- `runtime/workflow/history/size_ratio{app_id}` — extend the existing ratio metric to record on every dispatch, not only at the stall.
- `runtime/workflow/continue_as_new_suggested_total{app_id,reason}`
- `runtime/workflow/stalled_instances{reason}` — gauge (§4.3).

Phase 2:

- `runtime/workflow/payload/offload_total{component,direction,result}`
- `runtime/workflow/payload/offload_bytes{component,direction}`
- `runtime/workflow/payload/offload_latency_seconds{component,direction}`
- `runtime/workflow/payload/sweeper_deleted_total{component}` — the one to alert on; sustained non-zero means purge integration is broken and the sweeper is masking it.

The number to watch in phase 1 is the distribution of `history/size_ratio` across a fleet. A population clustered below 0.2 means the limit is a non-issue for that workload. A long tail above 0.5 that never continues-as-new is a fleet of future stalls, and today that is invisible until they arrive.

---

## 15. Documentation impact

- Update [workflow-payload-size](https://docs.dapr.io/developing-applications/building-blocks/workflow/workflow-payload-size/) with the suggestion tier, positioning ContinueAsNew as the *first* remedy rather than the third. The current page's ordering — raise the limit, force-purge, restructure — puts the operator-side workaround first and the correct fix last.
- New guidance distinguishing the two diseases: one large payload versus many small ones, and which remedy applies to each. This is the single most useful piece of prose that could be added, and it does not depend on either phase shipping.
- Document the ContinueAsNew unprocessed-events divergence across SDKs (§9.4) prominently, until it is fixed.
- For phase 2: a concept page, the encryption interaction, the lifecycle rules from §6.2 in bold, and an explicit statement that passing references remains preferred.
- A note that the stall guard requires 1.17.7+, since older runtimes fail differently and search results will not distinguish them.

---

## 16. Success criteria

1. A workflow accumulating history crosses a threshold and receives a suggestion with enough remaining budget to continue-as-new successfully, without operator involvement.
2. A workflow branching on that suggestion replays deterministically across a sidecar restart.
3. An operator receiving a stall message can tell from the message alone whether the cause is one large payload or many small ones, and which remedy applies.
4. Fleet-level payload pressure is visible as a distribution before any instance stalls.
5. *(Phase 2)* A 20 MiB activity output completes, replays byte-identically, and leaves no object in the store after the instance is purged.
6. *(Phase 2)* No configuration exists in which enabling offload moves plaintext out of an encrypted state store without an explicit acknowledgement.

---

## Appendix A — anticipating the main objection

Expect: *"This is what the docs already tell you to do. Pass references. Why does the runtime need to help?"*

For phase 2, that objection is largely correct and §12 concedes it. Discipline is the better answer, offload is a safety net, and the proposal should say so rather than oversell.

For phase 1 it does not hold, and the reason is worth stating precisely. The docs tell a developer what to do *before* writing the workflow. They do nothing for a workflow already running, already at 3.8 MiB, whose author is not watching. The runtime is the only participant that knows the number, and today it keeps that number to itself until the moment it is too late to act on — at which point the only remedy it offers is one only an operator can perform.

That is not a documentation gap. It is a missing signal, on a value the runtime already computes, that the workflow could act on if it were told.

## Appendix B — the interim pattern

Until any of this ships:

1. **Pass references.** Store the payload yourself, hand the workflow a key, fetch inside the activity. This is the documented advice, it is correct, and it remains correct afterward.
2. **Watch `runtime/workflow/payload/size_ratio`.** It exists as of 1.17.7 and most people do not know it does. Alert at 0.5, not 0.95 — by 0.95 the workflow is already stalled.
3. **Call ContinueAsNew on a fixed cadence** in any long-running workflow: every N iterations, every N activities, or on a timer. Without a suggestion signal, a fixed cadence is the only available approximation, and a conservative one costs little.
4. **Set a `stateRetentionPolicy`.** Default retention is indefinite; without one, history grows for the life of the cluster.
5. **Run 1.17.7 or later.** Older runtimes fail with `ResourceExhausted` on the dispatch stream and give no indication which workflow caused it.
6. **Never return a credential or a secret across an activity boundary**, whatever its size. Replay hands back the recorded value, so it is both stale on every replay and a durable copy in the state store.
