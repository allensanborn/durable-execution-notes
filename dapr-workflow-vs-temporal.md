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

The asymmetry is the tell that this is a design boundary rather than an oversight — `wait_for_external_event` *does* take a `timeout`. Waiting is bounded; working is not.

## 2. Workflow versioning

Any workflow whose instances run for weeks or months will have in-flight instances that outlive the code that started them. Temporal addresses this directly with patching (branch on whether a given change was present when a given instance started) and worker versioning (pin instances to a worker build).

Dapr's story here is thinner. The mitigation is to avoid needing it: keep instances short-lived and narrowly scoped, so the population of in-flight instances turns over faster than the deploy cadence, and keep an external ledger — not workflow history — as the system of record for long-running business state. Under that discipline, a versioning problem degrades into a restartable unit of work rather than a lost process.

## 3. Payload ceiling

A single workflow or activity dispatch in Dapr is bounded by the sidecar's `--max-body-size`, which defaults to **4 MiB**. Large tool output, plan diffs, or accumulated model context exceed that easily.

The discipline this forces is worth adopting regardless of engine: pass pointers, not blobs. Hand the workflow an identifier or a storage path and let the activity fetch the payload. It keeps history small, keeps replay fast, and keeps sensitive content out of the durable log by construction.

## 4. History hygiene and payload security

An event-sourced engine persists activity inputs and outputs. That makes anything returned across an activity boundary a durable artifact, which turns payload handling into a security design problem rather than a serialization detail.

**Temporal's model** is a client-side Data Converter with a pluggable Payload Codec. Data is plaintext only inside the client and worker processes you operate; the server stores ciphertext and never holds keys. On top of that sits the **Codec Server** — an HTTP service you run exposing `/decode`, `/encode`, and `/download`. The Web UI and CLI cannot decrypt anything themselves, so they call your codec server to render event history. The platform gets a decode service rather than a key, and every decode is an auditable request against infrastructure you control.

Temporal's own stated caveats: added UI latency from round-tripping payloads, oversized payloads needing external storage, CORS configuration for the Web UI, access control on the codec server being yours to get right, and — the important one — **failure messages and call stacks are not codec-encoded by default**.

**Dapr is not starting from zero.** It offers automatic client-side state-store encryption: AES-GCM with 128/192/256-bit keys, performed by the sidecar before data leaves the process, with keys always fetched from a secret store rather than sitting in component metadata, and primary/secondary keys for rotation. The `secretKeyRef.name` is appended to the state key so Dapr knows which key encrypted which item. Since Dapr Workflow persists through the actor state store, enabling encryption on that store does encrypt workflow history at rest.

The gaps are about control, not about ciphers:

1. **Granularity.** Encryption is all-or-nothing per state store. There is no way to mark one activity's output sensitive and leave the rest cheap and readable.
2. **Pluggability.** You get AES-GCM as implemented. There is no hook for your own KMS or HSM, envelope encryption, tokenization, or format-preserving encryption. Temporal's codec is your code.
3. **No decode path for tooling.** Dapr's encryption is transparent in the sidecar, so anything reading history for display — an operations console, a vendor control plane, a support engineer — either holds the key or sees ciphertext. There is no third option. This is the gap that matters most in a regulated multi-tenant deployment, where the requirement is usually that the vendor can render customer workflow state without ever holding the customer's keys.
4. **Failure paths.** Exceptions and stack traces carrying payload fragments leak regardless of state-store encryption. Temporal names this explicitly; Dapr should be assumed to have the same exposure.

A related rule holds on both engines and is easy to get wrong: **credentials must never cross an activity return boundary.** Replay hands back the recorded result, so a token returned from an activity is both a stale credential on every replay and a bearer credential sitting in durable storage. The durable artifact should be the long-lived *grant*; short-lived tokens are minted per use inside the activity and never persisted.

To close the gap, Dapr would need a per-payload codec hook in the workflow runtime running before the payload reaches the state store; a codec component type so it is swappable by YAML like every other Dapr concern; a decode endpoint contract so consoles and the CLI can render history without keys; per-activity or field-level sensitivity annotations so the codec applies selectively; failure and stack-trace scrubbing; and history purge/TTL controls tied to retention contracts.

## 5. Where Dapr leads

In a survey of six durable-execution and orchestration platforms plus Temporal, Dapr Agents' `DurableAgent` was the only one shipping a first-party, reusable **agent-loop class** — memory tiers, tool calling, and multi-agent orchestration as framework code — together with **SPIFFE-based per-agent cryptographic identity**. The others, Temporal included, provide a durable task or step primitive and leave the agent loop as application code, even where their marketing points at agents.

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
| Versioning long-running instances | Patching + worker versioning | Thin; mitigate with short-lived instances |
| Payload ceiling | Codec/external storage for oversized payloads | 4 MiB default per dispatch (`--max-body-size`) |
| History encryption | Client-side, pluggable payload codec | Sidecar AES-GCM on the state store |
| Selective/field-level encryption | Yes, codec is your code | No, all-or-nothing per store |
| Key-free decode for tooling | Codec Server (`/decode`, `/encode`) | None |
| Stack-trace payload leakage | Acknowledged, not covered by default | Same exposure, undocumented |
| First-party agent loop | No | Yes (`DurableAgent`) |
| Per-agent cryptographic identity | No | Yes (SPIFFE) |
| Scope | Dedicated durable-execution platform | One building block in a general runtime |

## Choosing between them

Prefer Temporal when workflows are long-running enough that in-flight instances will outlive several deploys, when individual activities are long or externally blocking and need per-attempt bounding, or when compliance requires selective payload encryption with a key-free decode path for operators.

Prefer Dapr Workflow when the surrounding application already runs on Dapr, when workflow instances can be kept short and an external ledger holds the durable business state, when activity bodies are idempotent by construction, and when a ready-made agent loop with per-agent identity is worth more than fine-grained execution control.

The gaps above are real, but none of them are architectural — they are missing control surfaces on a sound core, and the mitigations for each are structural rather than heroic.
