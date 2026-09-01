# Dapr Workflow vs. Temporal: where the gaps actually are

## The shared starting point

Both engines occupy the same category and use the same mechanism. Dapr Workflow is built on the Durable Task Framework — the same lineage as Azure Durable Functions — persists an event-sourced history, and recovers by deterministic replay. Temporal is likewise log-based. Neither serializes continuations the way a genuinely state-based runtime does, which is exactly why both impose determinism constraints on orchestrator code: the orchestrator may not call an LLM, read the clock, generate a random number, or perform I/O, and every side effect must live in an activity.

Calling Dapr Workflow "state-based" is a common and visible error. The determinism rules are the proof that it is not: a state-based engine that serialized continuations would need no such rules.

Because the core model matches, the real differences are in the control surfaces built around it.

## 1. Execution control: timeouts and heartbeats

This is the largest functional gap, and it is not subtle.

Temporal gives an activity four independent timeouts: schedule-to-start, start-to-close, schedule-to-close, and heartbeat. Dapr gives none. Verified against `dapr-ext-workflow` 1.18.3, the activity call signature is `call_activity(activity, *, input, retry_policy, app_id, propagation)` — there is no timeout parameter at any level.

There is also no activity heartbeat. The concept does not appear anywhere in `dapr/durabletask-go` and is absent from the documentation.

`RetryPolicy.retry_timeout` is not a substitute. It bounds total elapsed time *across* retries; it will not cancel a single attempt that has hung. A long-running activity that wedges mid-execution is therefore opaque to the engine — nothing detects it, nothing reclaims it.

Two consequences follow. First, because Dapr Workflow guarantees at-least-once execution, a worker lost mid-activity causes that activity to re-execute. Idempotency of the activity body is load-bearing correctness, not hygiene. Second, the practical mitigations are structural rather than configured: decompose long activities into smaller units, or dispatch the work out-of-band and complete the step via an external event.

This is a design boundary rather than an oversight, and the wire format is the proof: `ScheduleTaskAction` in the orchestrator-actions protobuf carries only `Name`, `Version`, `Input`, `TaskExecutionId`, and `HistoryPropagationScope`. No SDK could express an activity timeout without a protocol change. The asymmetry points the same way — `wait_for_external_event` *does* take a `timeout`. Waiting is bounded; working is not.

## 2. Workflow versioning

Any workflow whose instances run for weeks or months will have in-flight instances that outlive the code that started them. Temporal addresses this directly with patching (branch on whether a given change was present when a given instance started) and worker versioning (pin instances to a worker build).

Dapr addresses this with the same two mechanisms, both shipped in 1.18. Patch-based versioning (`IsPatched()` / `is_patched()`) wraps a change in a named conditional whose application is recorded in workflow history, so replays take a consistent path. Named workflow versioning registers a new versioned workflow type and routes new instances to the latest while in-flight instances stay pinned to the version they started on — `@wfr.versioned_workflow(is_latest=…)` in Python, `AddVersionedWorkflow(…, isLatest)` in Go, source-generated registration in .NET. Both are documented at [Workflow versioning](https://docs.dapr.io/developing-applications/building-blocks/workflow/workflow-versioning/), with the design rationale — including an explicit comparison to Temporal's implementation of both — in [`20251028-BRS-workflow-versioning.md`](https://github.com/dapr/proposals/blob/main/20251028-BRS-workflow-versioning.md).

The remaining difference is in kind, not presence. Temporal's Worker Versioning pins instances to a worker *build* at the deployment layer; Dapr's named versioning routes in the SDK's workflow registry. Dapr's proposal argues this is deliberate, minimizing versioning state in the runtime and letting each SDK use idiomatic registration — but it does mean the unit of pinning is a workflow type, not a worker deployment.

Keeping instances short-lived and holding long-running business state in an external ledger remains good practice, but it is now a design preference rather than a workaround for a missing feature.

## 3. Payload ceiling

A single workflow or activity dispatch in Dapr is bounded by the sidecar's `--max-body-size`, which defaults to **4 MiB**. Large tool output, plan diffs, or accumulated model context exceed that easily.

The limit is enforced as a stall rather than a hard failure: at 95% of the configured size the workflow is marked `PAYLOAD_SIZE_EXCEEDED` and parks, and it resumes if the cluster is rolled to a larger `--max-body-size`.

The discipline this forces is worth adopting regardless of engine: pass pointers, not blobs. Hand the workflow an identifier or a storage path and let the activity fetch the payload. It keeps history small, keeps replay fast, and keeps sensitive content out of the durable log by construction.

## 4. History hygiene and payload security

An event-sourced engine persists activity inputs and outputs. That makes anything returned across an activity boundary a durable artifact, which turns payload handling into a security design problem rather than a serialization detail.

**Temporal's model** is a client-side Data Converter with a pluggable Payload Codec. Data is plaintext only inside the client and worker processes you operate; the server stores ciphertext and never holds keys. On top of that sits the **Codec Server** — an HTTP service you run exposing `/decode`, `/encode`, and `/download`. The Web UI and CLI cannot decrypt anything themselves, so they call your codec server to render event history. The platform gets a decode service rather than a key, and every decode is an auditable request against infrastructure you control.

Temporal's own stated caveats: added UI latency from round-tripping payloads, oversized payloads needing external storage, CORS configuration for the Web UI, access control on the codec server being yours to get right, and — the important one — **failure messages and call stacks are not codec-encoded by default**.

**Dapr is not starting from zero.** It offers automatic client-side state-store encryption: AES-GCM with 128/192/256-bit keys, performed by the sidecar before data leaves the process, with keys always fetched from a secret store rather than sitting in component metadata, and primary/secondary keys for rotation. The `secretKeyRef.name` is appended to the stored **value**, after a `||` separator, so Dapr knows which key encrypted which item. (Dapr's own documentation says the key name is appended to the state key; the implementation in `pkg/encryption/state.go` appends it to the value. The code is authoritative.) Since Dapr Workflow persists through the actor state store, enabling encryption on that store does encrypt workflow history at rest.

The gaps are about control, not about ciphers:

1. **Granularity.** Encryption is all-or-nothing per state store. There is no way to mark one activity's output sensitive and leave the rest cheap and readable.
2. **Pluggability.** You get AES-GCM as implemented. There is no hook for your own KMS or HSM, envelope encryption, tokenization, or format-preserving encryption. Temporal's codec is your code.
3. **No decode path for tooling.** Dapr's encryption is transparent in the sidecar, so anything reading history for display — an operations console, a vendor control plane, a support engineer — either holds the key or sees ciphertext. Dapr offers no third option. This is the gap that matters most in a regulated multi-tenant deployment, where the requirement is usually that the vendor can render customer workflow state without ever holding the customer's keys.
4. **Failure paths.** Exceptions and stack traces carrying payload fragments leak regardless of state-store encryption. Temporal names this explicitly; Dapr should be assumed to have the same exposure.

A related rule holds on both engines and is easy to get wrong: **credentials must never cross an activity return boundary.** Replay hands back the recorded result, so a token returned from an activity is both a stale credential on every replay and a bearer credential sitting in durable storage. The durable artifact should be the long-lived *grant*; short-lived tokens are minted per use inside the activity and never persisted.

This is worth separating from the encryption question, because the two are often conflated. There are **two distinct history-hygiene problems**, and only one of them is solved by a codec. Business payloads are legitimately persisted and legitimately need to be readable later, so encryption with a controlled decode path is the right answer for them. Credentials are the opposite case: replay semantics forbid persisting them *at all*, encrypted or not, because a token handed back from history is stale by the time it is replayed. Encrypting a token in history makes it a confidential stale credential rather than a readable one; it does not make it correct.

The consequence for design is that a durable engine needs both mechanisms, and they are not substitutes. [A separate proposal in this repository](dapr-delegated-identity-proposal.md) works out the credential half for Dapr: a delegation context that carries non-secret authority across workflow boundaries, from which a fresh token is minted inside the sidecar at call time. Its central correctness property — that the subject token is never written to durable storage — is this rule stated as an enforceable runtime invariant rather than a convention.

To close the gap, Dapr would need a per-payload codec hook in the workflow runtime running before the payload reaches the state store; a codec component type so it is swappable by YAML like every other Dapr concern; a decode endpoint contract so consoles and the CLI can render history without keys; per-activity or field-level sensitivity annotations so the codec applies selectively; failure and stack-trace scrubbing; and history purge/TTL controls tied to retention contracts.

## 5. Where Dapr leads

Dapr Agents' `DurableAgent` is a first-party, reusable **agent-loop class** — memory tiers, tool calling, and multi-agent orchestration as framework code, in a single `AgentBase` subclass. Most durable-execution platforms ship no such thing; they provide a durable task or step primitive and leave the agent loop as application code.

Two qualifications matter. First, the cryptographic identity often attributed to `DurableAgent` is not its feature: every Dapr sidecar receives a Sentry-issued SVID bound to `spiffe://<trust-domain>/ns/<namespace>/<app-id>`, so an agent deployed as its own Dapr app gets workload identity for free. That is a property of the runtime the agent sits on — the string `spiffe` does not appear anywhere in the `dapr/dapr-agents` repository. Per-agent identity follows from deployment convention, not from the framework.

Second, Temporal is a partial exception rather than a clean contrast. It ships no agent-loop class of its own, but `temporalio.contrib.openai_agents` — first-party, in the Python SDK repository, GA since March 2026 — supplies a `Runner` that drives the OpenAI Agents SDK's loop and turns every LLM and tool call into an activity automatically. Temporal wraps someone else's loop durably; Dapr Agents defines its own.

That is a genuine advantage and also a genuine tension: a framework-owned control loop is the thing agent-engineering practice most often tells you to keep in your own hands. The trade is real convenience against real control, and which side wins depends on how unusual the loop needs to be.

Dapr's broader position also differs in kind rather than degree: it is a general-purpose distributed-application runtime in which workflow is one building block alongside state, pub/sub, bindings, and service invocation. Temporal is a dedicated durable-execution platform. If the surrounding application already runs on the rest of Dapr, the workflow engine arrives with the infrastructure already in place.

## Summary

| Dimension | Temporal | Dapr Workflow |
|---|---|---|
| Execution model | Log-based, event-sourced, deterministic replay | Same (Durable Task Framework lineage) |
| Determinism constraints | Yes | Yes |
| Activity timeouts | Four (schedule-to-start, start-to-close, schedule-to-close, heartbeat) | None |
| Activity heartbeat | Yes | No |
| Hung-attempt cancellation | Via start-to-close / heartbeat | None; `retry_timeout` bounds retries only |
| Delivery semantics | At-least-once; idempotency required | At-least-once; idempotency required |
| Versioning long-running instances | Patching + worker versioning (pins to worker build) | Patching + named workflow versions (pins to workflow type), 1.18 |
| Payload ceiling | Codec/external storage for oversized payloads | 4 MiB default per dispatch (`--max-body-size`); stalls at 95% |
| History encryption | Client-side, pluggable payload codec | Sidecar AES-GCM on the state store |
| Selective/field-level encryption | Yes, codec is your code | No, all-or-nothing per store |
| Key-free decode for tooling | Codec Server (`/decode`, `/encode`) | None |
| Stack-trace payload leakage | Acknowledged, not covered by default | Presumed same exposure; not documented either way |
| First-party agent loop | No class of its own; first-party OpenAI Agents SDK integration | Yes (`DurableAgent`) |
| Per-app SPIFFE workload identity | No | Yes, via Dapr Sentry — not the agent framework |
| Scope | Dedicated durable-execution platform | One building block in a general runtime |

## Choosing between them

Prefer Temporal when individual activities are long or externally blocking and need per-attempt bounding, when compliance requires selective payload encryption with a key-free decode path for operators, or when you want in-flight instances pinned to a worker build rather than to a workflow type.

Prefer Dapr Workflow when the surrounding application already runs on Dapr, when activity bodies are idempotent by construction, and when a ready-made agent loop with per-agent identity is worth more than fine-grained execution control.

The gaps above are real, but none of them are architectural — they are missing control surfaces on a sound core, and the mitigations for each are structural rather than heroic.

---

## A note on method

Every claim about current behavior in this document was checked against source at a pinned commit rather than against documentation prose, and that process changed the document's conclusions. An earlier draft asserted that Dapr's workflow versioning story was thin; it is not, and `is_patched` sits about a hundred lines below the `call_activity` signature the timeout claims were verified against, in the same file of the same release. An earlier draft also credited `DurableAgent` with SPIFFE-based per-agent identity, which the framework does not implement.

Both errors ran in the same direction — overstating a gap — which is the direction a comparison written from one side tends to fail in. Where documentation and code disagreed, as they do on which field the encryption key name is appended to, the code is treated as authoritative and the discrepancy is noted rather than silently resolved.
