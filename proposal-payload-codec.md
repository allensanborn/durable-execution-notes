# Proposal: Workflow Payload Codec and Decode Service

**Status:** Draft
**Target repo:** `dapr/proposals`
**Affects:** `dapr/dapr`, `dapr/durabletask-go`, `dapr/components-contrib`, CLI, docs
**Author:** Allen Sanborn
**Date:** 2026-09

---

## 0. Provenance

Every claim about current behavior below was read out of source at these commits. Anything I could not
confirm in code or in a primary doc is marked **unverified** inline.

| Repo | Commit | Date |
| --- | --- | --- |
| `dapr/dapr` | `12463d2` | 2026-09-01 |
| `dapr/components-contrib` | `ece1f25` | 2026-08-24 |
| `dapr/durabletask-go` | `18cd4b5` | 2026-08-26 |
| `dapr/proposals` | `9ca8958` | 2026-03-25 |
| `temporalio/samples-go` | `3c8a12e` | 2026-08-20 |

---

## 1. Abstract

An event-sourced engine persists activity inputs and outputs. That makes anything crossing an activity
boundary a durable artifact, which turns payload handling into a security design problem rather than a
serialization detail.

This proposal adds three things to Dapr Workflow:

1. A **payload codec applied in the workflow runtime**, at the boundary where history events are
   marshaled for persistence, backed by the existing `crypto` building block rather than a new
   component type.
2. A **selection policy** expressed in Dapr `Configuration`, defaulting to encode-everything with
   explicit carve-outs, so that forgetting to annotate something cannot leak it.
3. A **Dapr Codec Server** — a standalone decode service speaking a superset of Temporal's codec
   protocol — so that a console, a support engineer, or a vendor control plane can render workflow
   history without ever holding the customer's keys.

It also fixes the failure path, which is where both engines leak today.

The design goal is that application and activity code is **byte-for-byte unchanged**, and that a
correctly-configured deployment leaks nothing at rest even when a developer forgets to think about it.

Two findings from reading the code changed the shape of this proposal and should be read before the
rest of it:

- **Dapr's state-store encryption does not cover workflow history.** It is applied only in the state
  building block's API layer. The actor state path — which is how workflow history is persisted — never
  touches it. See §2.2. The premise that "enabling encryption on the actor state store encrypts
  workflow history" is, as far as the code shows, false.
- **Dapr has no history read API at all.** `GetWorkflowBeta1` returns metadata plus a flat property
  map; there is no RPC that returns event history. A decode service therefore has a hard prerequisite
  that does not exist yet. See §4.4.

---

## 2. Background

### 2.1 What Dapr already has

**A `crypto` building block that is closer to a codec than it first appears.** The `crypto` category
exists (`dapr/pkg/components/category.go:29`), with a `SubtleCrypto` component contract
(`components-contrib/crypto/subtlecrypto.go`) offering `Encrypt`/`Decrypt`/`WrapKey`/`UnwrapKey`/
`Sign`/`Verify` against a vault, and shipped components for Azure Key Vault, Kubernetes secrets, JWKS,
and local storage (`components-contrib/crypto/{azure/keyvault,kubernetes/secrets,jwks,localstorage}`).

Layered on that is a **high-level envelope-encryption API**. `pkg/api/grpc/crypto.go:72-84` builds an
`encv1.EncryptOptions` carrying a `WrapKeyFn` bound to the component, and streams data through the
`dapr.io/enc/v1` scheme (`github.com/dapr/kit/schemes/enc/v1`). The original proposal
(`dapr/proposals/20230327-RCBS-Crypto-building-block.md`) describes the scheme as modeled on Tink's wire
format, `age`, and Minio's DARE, and states the building block's purpose in a line that decides §4.2 of
this document: *"Keeping keys outside of applications. Applications never see key material, but can
request the vault to perform operations with the keys."*

The envelope is self-describing: `EncryptOptions` has `OmitKeyName` and `DecryptionKeyName`, so by
default the key name rides in the envelope and decrypt does not need to be told which key was used.
That is exactly the property a decode service needs.

**A history-signing chain.** `dapr/pkg/actors/targets/workflow/orchestrator/signing/sign.go:58-80`
marshals each new history event with `historysigning.MarshalEvent`, stores those exact bytes via
`state.SetMarshaledNewHistory`, and signs them into a chain with a Sentry-issued signer. Activity
completions additionally carry an attestation whose `ioDigest` covers the activity's input and output
(`orchestrator/signing/attach.go:102-121`). This is a real constraint on any codec — see §4.6 — and it
is also evidence that the Dapr team has already accepted the idea of a runtime-owned transform sitting
at exactly the boundary this proposal targets.

**State-store encryption.** `dapr/pkg/encryption/` implements AES-GCM with primary/secondary keys
pulled from a secret store (`encryption.go:53-120`), hex-decoded (`createCipher`, `encryption.go:180`),
with the `secretKeyRef.name` appended to the stored value after a `||` separator so the right key can be
selected on read (`state.go:26,52`). The docs confirm hex encoding, 128/192/256-bit support, the
recommendation of 128-bit, and the secondary-key rotation story.

**Retention.** `WorkflowStateRetentionPolicy` (`dapr/pkg/apis/configuration/v1alpha1/types.go:191-215`)
already supports per-terminal-state TTLs — `anyTerminal`, `completed`, `failed`, `terminated` — accepting
duration strings including `0s`. History purge/TTL is therefore **already solved** and is removed from
this proposal's scope. Earlier gap analyses that list it as missing are out of date.

### 2.2 The gap, corrected

The gap is not "Dapr encrypts history coarsely." It is that **Dapr does not encrypt workflow history at
all**, and the mechanism people assume covers it does not.

`grep` for the encryption package across `dapr/dapr` returns exactly five non-test importers:

```
pkg/api/grpc/grpc.go
pkg/api/http/http.go
pkg/api/universal/state_query.go
pkg/runtime/processor/state/state.go   (registration only)
```

Every call site is in the **state building block's public API** — `grpc.go:658,724,792,1035` and
`http.go:585,684,1039,1600`. Workflow history does not go through that API. It is written by
`pkg/actors/state/state.go`, which imports `contribstate` and calls `store.Multi` / `store.Get`
directly (`state.go:22-30,248`) and contains no reference to `pkg/encryption`. There are **zero**
occurrences of the string `encrypt` (case-insensitive, non-test) anywhere under `dapr/pkg/actors/` or
`dapr/pkg/runtime/wfengine/`.

The docs do not contradict this so much as decline to address it: the state-encryption how-to says the
feature is "supported by all Dapr state stores" and never mentions actors or workflows. The silence is
where the wrong inference comes from.

So the four gaps against Temporal are one gap plus three:

| # | Gap | Status |
| --- | --- | --- |
| 0 | Workflow history is not encrypted by any mechanism | **The actual gap.** Verified above |
| 1 | Granularity — no way to mark one activity's output sensitive | Real. Also true of Temporal in practice; see §2.3 |
| 2 | Pluggability — no hook for your own KMS/HSM, envelope encryption, tokenization | Real for workflow. Partly already solved for other data by the `crypto` building block |
| 3 | No key-free decode path for tooling | Real, and blocked on a prerequisite Dapr does not have (§4.4) |
| 4 | Failure paths leak payload fragments | Real, and demonstrably so — `task/executor.go:119` |

There is no encryption, codec, or data-protection proposal in `dapr/proposals` covering workflow
payloads. The nearest neighbours are the crypto building block proposal (2023-03-27), the workflow
versioning proposal (`20251028-BRS-workflow-versioning.md`), and the MCPServer proposal
(`20260304-CR-mcpserver.md`). This is unclaimed ground.

### 2.3 What Temporal actually does, and where the usual summary is too generous

Temporal's model is a client-side **Data Converter** wrapping a **Payload Codec**
(`converter.NewCodecDataConverter`). The codec is a pair of pure functions over
`[]*commonpb.Payload`, and it runs in the client and worker processes, so the server stores ciphertext
and never holds keys. The reference implementation is
`temporalio/samples-go/encryption/data_converter.go`, which sets
`Metadata[MetadataEncoding] = "binary/encrypted"` and `Metadata["encryption-key-id"] = KeyID`.

On top sits the **Codec Server**, an HTTP service exposing `/decode`, `/encode`, and — only when workers
use external storage — `/download`. The protocol (`samples-go/codec-server/README.md`) is short and
good:

- Body is a `Payloads` protobuf as protobuf-JSON, in and out.
- Implementations **MUST** "only check the final part of the incoming URL to determine if the request is
  for /encode or /decode," so the endpoints can be mounted at any depth.
- Namespace may come from the URL or from an `X-Namespace` header.
- Errors are `400` for invalid JSON or codec failure; success is `200`.

The sample server (`samples-go/codec-server/codec-server/main.go`) adds OIDC via
`Authorization: Bearer`, mapping claims to Temporal roles: `RoleReader` for `/decode`, `RoleWriter` for
`/encode` (`oidc.go:41-52`). CORS is a single origin from a `-web` flag.

Temporal's own documented caveats, which any honest proposal has to inherit:

- "You may introduce latency in the Web UI when sending and receiving payloads to the Codec Server."
- Access control on the codec server is the operator's problem; the docs say only that "access to a
  production Codec Server should be restricted."
- CORS must be configured for the Web UI, including `X-Namespace`.
- **"Failure messages and call stacks are not encoded as codec-capable Payloads by default; you must
  explicitly enable encoding these common attributes on failures."** The opt-in is
  `DefaultFailureConverterOptions{EncodeCommonAttributes: true}`, which moves `message` and
  `stack_trace` into a `Payload` in `Failure.encoded_attributes` and runs it through the codec.

Two corrections to how Temporal is usually described in Dapr-vs-Temporal comparisons:

**Temporal's codec is not selective either.** The Data Converter is set once on the client and applies
to every payload that worker produces. The encryption sample varies the *key ID* per workflow via a
context propagator (`samples-go/encryption/propagator.go`), not the *decision to encrypt*. Nothing in
the framework marks one activity's output as sensitive. Achieving that requires writing a custom
`PayloadConverter` that inspects types and sets metadata — possible, but it is your code, not a feature.
Claiming Dapr lacks selective encryption *that Temporal has* overstates the gap; the honest statement is
that neither has it and this proposal adds it.

**The codec server's authorization is coarser than it looks.** The request body is a bare list of
payloads. There is no instance ID, no workflow name, no event ID. The only context is the namespace,
carried in the URL or a header. A codec server therefore cannot make a per-workflow decision, cannot
write an audit record naming what was decoded, and cannot redact selectively. Every decode is
all-or-nothing at namespace granularity. This is the thing most worth changing (§4.4).

### 2.4 Why this belongs in the runtime

Three reasons, in ascending order of force.

**The runtime is where the boundary is.** History events become durable in exactly one place:
`pkg/runtime/wfengine/state/state.go`, where `GetSaveRequest` (line 448) and its helpers
`addStateOperations` (640), `addProtoStateOperations` (678) and `addRawBytesStateOperations` (705)
marshal events into an actor transactional request, and `loadWorkflowStateOnce` (733) reverses it.
A codec that sits anywhere else is either too early to see everything or too late to matter.

**The sidecar already has the plaintext.** This is the argument that decides §4.1. daprd builds the
outbound `ActivityRequest`, measures it with `proto.Size` for the payload ceiling
(`orchestrator/payloadsize.go:49-60`), computes attestation digests over the plaintext input and output
(`orchestrator/signing/attach.go:104-118`), and re-exports the workflow's input, output, custom status,
error message, and stack trace as plaintext strings over the management API
(`pkg/api/universal/workflow.go:98-118`). Putting a codec in the sidecar does not newly expose anything
to daprd. Putting it in the SDK would require pulling three existing sidecar-side features back out.

**Dapr's own design principle points the other way from Temporal's.** Temporal's codec is client-side
because in Temporal the untrusted party is the *service* — possibly Temporal Cloud, run by a different
operator, in a different trust boundary. Dapr has no equivalent central service. The nearest analogue is
the state store, which is usually managed Redis/Postgres/Cosmos operated by someone else, plus whoever
can call the workflow management API. A sidecar-side codec covers both. And the `crypto` building block
was created to keep key material *out* of application processes; an SDK-side codec would put it back in,
in five languages. Copying Temporal's placement copies an answer to a question Dapr is not asking.

---

## 3. The boundary with delegated identity (read this before §4)

This proposal and [`dapr-delegated-identity-proposal.md`](dapr-delegated-identity-proposal.md) both
concern secrets in workflow history, and they prescribe **opposite** mechanisms. They are not
alternatives and they must not be confused.

| | Business payload — **this** proposal | Credential — **delegated identity** |
| --- | --- | --- |
| Persisted in history? | **Yes, by design** | **Never, under any encryption** |
| Why | Deterministic replay must reproduce it | Replay hands back the *recorded* value, so a token is stale on every replay after the first |
| Read back later? | Yes — that is the point | No — reading it back is the bug |
| Mechanism | Encode at the history boundary; decode through a key-free service | Do not put it there. Carry a small non-secret grant; mint the credential inside the sidecar at call time |
| Is encryption sufficient? | Yes | **No.** Encryption answers confidentiality; a credential's security property is *freshness*, and no cipher provides freshness |
| Failure mode if you get it wrong | Plaintext business data at rest | A bearer credential at rest **and** a workflow that breaks on replay |

The rule, in one line: **if reading it later is the point, encode it; if reading it later is the bug,
never write it.**

Two concrete couplings between the documents:

- The delegated-identity proposal's §4.2 persistence invariant says `DelegationContext` (minus
  `SubjectToken`) is persisted with workflow instance metadata "encrypted at rest through the existing
  `crypto` building block when a crypto component is configured." **No such path exists today** — that is
  the §2.2 finding. This proposal is the implementation that makes that sentence true. §4.3's policy
  `scope` therefore includes `instanceMetadata`, not only history payloads.
- That proposal's §11.3 raw-state-store-scan test and this proposal's §11.2 test are the same test with
  different search strings. They should be one suite, so that neither invariant can regress without the
  other's test noticing.

Anything a reader takes away from this document should include: **a codec is not an excuse to persist a
token.**

---

## 4. Design

### 4.1 Where the hook goes

This is the central tension and it deserves a straight answer rather than a compromise.

The two placements:

| | **Sidecar-side** (proposed) | **SDK-side** (Temporal's model) |
| --- | --- | --- |
| Plaintext crosses a process boundary | Yes — app ↔ daprd gRPC | No |
| Implementations needed | One, in Go | Five: Go, .NET, Java, Python, JS |
| Key material location | Vault, reached by daprd via `crypto` component | Application process |
| Cross-language envelope compatibility | Free | A new normative wire spec every SDK must match byte-for-byte |
| Protects against a compromised state store | Yes | Yes |
| Protects against a compromised sidecar | **No** | Yes |
| Protects against a compromised app | No | No |
| Interacts with existing sidecar-side attestation / payload-ceiling / management-API code | Cleanly | Requires reworking all three |

**Proposal: sidecar-side, in `pkg/runtime/wfengine/state`.**

The honest accounting of what that costs:

Plaintext travels from the app process to daprd over the workflow work-item gRPC stream. In Kubernetes
the injector defaults `--dapr-listen-addresses` to `[::1],127.0.0.1`
(`dapr/pkg/injector/patcher/sidecar.go:87`), so that traffic stays inside the pod's network namespace and
never reaches a network interface. In self-hosted mode the default is different and worse:
`DefaultAPIListenAddress = ""` (`dapr/pkg/runtime/config.go:65`), meaning all addresses. Any deployment
relying on this proposal should set listen addresses to loopback explicitly, and the docs must say so
rather than leaving the Kubernetes default to imply a guarantee self-hosted does not provide.

What that boundary does *not* do is create new exposure, because the plaintext is already there. daprd
holds the activity input and output in memory to size-check it, digest it for attestation, and serve it
over `GetWorkflowBeta1`. A threat model that excludes the sidecar is a threat model in which Dapr
Workflow already cannot be used, independent of this proposal.

For the minority whose threat model genuinely does exclude the sidecar — typically because daprd is
operated by a different team than the application — §10 phase 3 reserves an SDK-side **sealed payload**
escape hatch: an opaque, already-encoded value the SDK produces and the sidecar treats as opaque bytes.
It is deliberately worse ergonomically (no attestation over plaintext, no size introspection, per-language
implementation) and it is not the default. Naming it keeps the door open without pretending the two
placements are equivalent.

#### Placement in the pipeline

Field-level, not blob-level, applied to the payload-bearing fields of `HistoryEvent`:

```
TaskScheduledEvent.Input
TaskCompletedEvent.Result
TaskFailedEvent.FailureDetails       (see §4.5)
ExecutionStartedEvent.Input
ExecutionCompletedEvent.Result
EventRaisedEvent.Input
SubOrchestrationInstanceCreated.Input / Completed.Result
custom status
```

Encode runs in `State.GetSaveRequest` (`wfengine/state/state.go:448`), before
`historysigning.MarshalEvent` in `signing/sign.go:58`. Decode runs in `loadWorkflowStateOnce`
(`state.go:733`), after unmarshal and after signature verification.

Field-level rather than blob-level because blob-level forecloses everything else in this proposal:
event type and IDs must stay readable for indexing and for the ceiling accounting in
`payloadsize.go`; selectivity per activity (§4.3) requires knowing which field belongs to which
activity; and a decode service that returns per-field results (§4.4) needs fields.

### 4.2 Component type: extend `crypto`, do not invent `codec` (yet)

Both options were live. The argument:

**Reusing `crypto` gets an enormous amount for free, and most of it is the hard part.** Envelope
encryption with a KMS/HSM-held KEK is already implemented and shipped
(`pkg/api/grpc/crypto.go:72-84`, `kit/schemes/enc/v1`). The envelope is self-describing, so rotation
works without a rotation protocol: the key name rides in the ciphertext and decrypt finds it. Component
scoping, `components.deny`, secret injection, and metadata validation all already apply to the `crypto`
category (`pkg/components/category.go:29`). Four components exist. A new `codec` type would spend its
first two releases reimplementing this and would get the envelope format subtly wrong at least once.

**A new type gets a cleaner contract, and that matters for the things crypto genuinely cannot express.**
`SubtleCrypto` (`components-contrib/crypto/subtlecrypto.go`) is a *key operations* interface:
`Encrypt`, `WrapKey`, `Sign`. Tokenization, format-preserving encryption, redaction, and
external-blob offload are not key operations. They are `[]Payload → []Payload` transforms, which is
precisely Temporal's `PayloadCodec` shape, and forcing them through `WrapKey` would distort the
interface for no benefit.

**Proposal: two tiers, shipped in order.**

**Tier 1 — a crypto-backed codec, no new component type.** The policy names a `crypto` component and a
key; the runtime performs `dapr.io/enc/v1` envelope encryption. This covers the entire regulated
use case — customer-managed keys in a customer-controlled KMS or HSM, per-tenant keys, rotation without
re-encryption — with zero new component surface.

**Tier 2 — a `codec` component type, phase 3, only if demand justifies it.**

```go
package codec

// Codec transforms workflow payloads on their way to and from durable storage.
type Codec interface {
    metadata.ComponentWithMetadata

    Init(ctx context.Context, meta Metadata) error

    // Encode transforms plaintext payloads into their persisted form.
    // MUST be deterministic in shape (same count, same order) but need not be
    // byte-deterministic; nonces are expected to vary.
    Encode(ctx context.Context, in []Payload) ([]Payload, error)

    // Decode reverses Encode. MUST be a total inverse for anything Encode
    // produced, across key rotations, for the configured retention window.
    Decode(ctx context.Context, in []Payload) ([]Payload, error)

    io.Closer
}

type Payload struct {
    Data     []byte
    Metadata map[string][]byte // self-describing; carries the encoding tag
}
```

Deliberately identical in shape to `converter.PayloadCodec` so that a Temporal codec ports in an
afternoon, and implementable as a **pluggable component** over gRPC
(`dapr/pkg/components/pluggable/`) so a tokenization vendor can ship one without a Dapr fork.

Tier 2 also happens to solve the 4 MiB payload ceiling, since an offload codec that replaces a large
payload with a storage reference is the same mechanism as DataDog's
`temporal-large-payload-codec`. That is the natural home for a `/download` endpoint (§4.4), and it is
the reason to keep the tier-2 contract in view even while shipping tier 1.

### 4.3 Selective application, with the polarity reversed

Three designs were on the table. The deciding question is what happens when someone forgets.

| Design | On omission | Reviewable in one place | Verdict |
| --- | --- | --- | --- |
| Per-activity annotation / attribute in code | **Fails open** — plaintext, silently | No, scattered across the codebase | Reject as the primary mechanism |
| Type marker in the SDK (`[Sensitive] class SsnResult`) | **Fails open**, and per-language | No | Reject as the primary mechanism |
| Config policy matching activity names | Depends entirely on the default | Yes, operator-owned, diffable | Accept, **with `default: encode`** |

"Mark the sensitive ones" is the wrong polarity. Sensitivity is discovered late — an activity returns a
customer record two years after it was written, and nobody revisits the annotation. A design in which
forgetting leaks is a design that leaks. The correct default is encode-everything with explicit,
reviewed exceptions, which is the same posture Dapr's `components.deny` and API allowlists already take.

```yaml
apiVersion: dapr.io/v1alpha1
kind: Configuration
metadata:
  name: agentconfig
spec:
  features:
    - name: WorkflowPayloadCodec
      enabled: true
  workflow:
    payloadCodec:
      crypto:
        component: corp-kms          # a crypto component
        key: wf-payload-kek
        algorithm: RSA-OAEP-256      # key-wrap algorithm; DEK is per-instance
      default: encode                # encode | passthrough. Default is encode.
      scope: [input, output, customStatus, failure, instanceMetadata]
      rules:
        - match: { activity: "FetchPublicCatalog" }
          action: passthrough
        - match: { workflow: "PublicStatusPoll", activity: "*" }
          action: passthrough
```

Rules are ordered, first match wins, `default` applies last. Matching is on workflow name, activity
name, and event kind, with glob syntax only — no regex, because regex invites both ReDoS and rules no
reviewer can read.

**Composition with an SDK hint, and the rule that makes it safe.** A developer may mark an activity
`sensitive: true` in SDK code. That hint can only **tighten**: it can promote a `passthrough` to
`encode`, and can never demote an `encode` to `passthrough`. Operator policy is a floor, application
code raises it. This gets the ergonomic win of code-local annotation without reintroducing the
fail-open mode, because the annotation's absence is never load-bearing.

**What is explicitly rejected: field-level encryption inside a payload.** Encrypting one JSON field
requires the runtime to parse and understand user payload structure, in every serialization format the
SDKs emit. It is a large, brittle surface for a benefit — "the non-sensitive half of this object stays
queryable" — that Dapr cannot deliver anyway, since it has no history query API to query with. Users
who genuinely need it should use a tier-2 tokenization codec (§4.2), where the transform is their code
and understands their schema.

### 4.4 The decode service

#### The prerequisite nobody has mentioned

**Dapr's workflow API returns no history.** `dapr/dapr/proto/runtime/v1/workflow.proto:38-51` defines
`GetWorkflowResponse` as instance ID, workflow name, created-at, last-updated-at, runtime status, and a
`map<string, string> properties`. `dapr.proto:185-238` lists every workflow RPC — start, get, purge,
terminate, pause, resume, raise-event — and there is no history RPC in either the alpha or beta set.

A decode service exists to let tooling render history. Dapr has no history for tooling to render. So
**a workflow history read API is a hard prerequisite of this section**, and it should be filed as its own
proposal rather than smuggled in here. Until it exists, §4.4 has exactly one consumer: the property map
returned by `GetWorkflow`, which today ships `dapr.workflow.input`, `dapr.workflow.output`,
`dapr.workflow.custom_status`, `dapr.workflow.failure.error_message` and
`dapr.workflow.failure.stack_trace` as plaintext to any caller holding `workflow` API access
(`pkg/api/universal/workflow.go:98-118`). That is a real leak worth closing on its own, and it is the
minimum viable consumer of a decode path.

#### What ships: a standalone Dapr Codec Server

A small binary that loads a Dapr `crypto` component and a codec policy, and serves decode requests. It
runs **inside the data owner's trust boundary**. The console, CLI, or vendor control plane calls it. The
caller never holds a key. This is the piece that makes regulated multi-tenant deployments possible:
the vendor renders customer workflow state without ever possessing customer key material.

#### Wire contract

Adopt Temporal's protocol as the base — it is well designed, and existing CLI and UI clients already
speak it — with the deltas below.

```
POST /{path...}/decode
POST /{path...}/encode          # off by default; see delta 6
POST /{path...}/download        # tier-2 codecs only; see §4.2
Content-Type: application/json
```

Kept verbatim from Temporal:

- Body is a `Payloads` message serialized as **protobuf-JSON**, not the language's native JSON encoder.
- **Only the final path segment determines the operation.** This is genuinely good design — it lets the
  endpoints be mounted at any depth so one host can serve many tenants — and it should be copied
  without modification.
- `400` for malformed JSON or codec error, `200` with transformed payloads on success.

Seven deltas, in descending order of importance:

**1. Carry instance context, in headers.** Temporal's request body is a bare payload list; the only
context is a namespace. That makes per-workflow authorization impossible and makes an audit record
meaningless. Require:

```
X-Dapr-App-Id: expenses-agent
X-Dapr-Workflow-Instance-Id: wf-8f3c...
X-Dapr-Namespace: prod-eu          # replaces X-Namespace
X-Dapr-Event-Ids: 14,15,16         # optional, for audit precision
```

Headers rather than body fields, so the body stays wire-compatible with the Temporal protocol and a
Temporal codec implementation ports across unchanged.

**2. Decode is an audited read, not merely an authorized one.** Every `/decode` emits a structured audit
event: caller identity, namespace, app ID, instance ID, event IDs, payload count, and per-payload
decision. Temporal's sample server logs nothing at all. In a regulated deployment "who read this
customer's workflow state, and when" is the question the auditor actually asks, and an unlogged decode
service cannot answer it. Audit emission is not optional and not configurable off.

**3. Authenticate with SPIFFE and OIDC, because there are two kinds of caller.** A service calling as
itself should present a Sentry-issued X.509 SVID over mTLS, and be authorized on its SPIFFE ID. A human
console session should present an OIDC bearer token, exactly as Temporal's sample does
(`codec-server/codec-server/oidc.go:22-52`). Support both; Sentry has been an OIDC issuer since 1.16, so
both paths can be rooted in the same trust domain.

Authorization is expressed as a policy the operator writes, evaluated per request against
`(caller identity, namespace, app ID, instance ID)`. The proposal should say plainly, as Temporal's docs
do, that **getting this right is the operator's responsibility** — but unlike Temporal it should ship a
default policy that denies everything, so an unconfigured codec server is useless rather than open.

**4. Per-payload results, so partial decode is expressible.** Temporal's protocol is all-or-nothing:
either every payload decodes or you get a 400. Return a parallel result array:

```json
{
  "payloads": [ { "metadata": {...}, "data": "..." } ],
  "results":  [ { "status": "decoded" },
                { "status": "redacted", "reason": "field-class:pii" },
                { "status": "denied",   "reason": "no-grant-for-instance" } ]
}
```

A support engineer debugging a stuck workflow needs to see its *shape* — which activity failed, in what
order, with what error type — far more often than they need the customer's data. All-or-nothing forces
the operator to choose between a useless console and an over-broad grant. Per-payload results let a
policy return structure and withhold content, which is the outcome everyone actually wants.

**5. Version the protocol.** `X-Dapr-Codec-Protocol: 1` on request and response. Temporal's protocol has
no version field, which will eventually hurt.

**6. `/encode` is off by default.** An encode endpoint on a shared codec server is an encryption oracle:
it will produce a validly-encoded payload for any input, addressed to the tenant's key. Temporal's
sample gates it behind `RoleWriter` but still mounts it. Dapr should ship decode-only, with `/encode`
behind an explicit `--enable-encode` flag and a documented statement of why you probably do not want it.

**7. CORS is an explicit allowlist, shipped, never `*`.** Temporal's sample takes a single origin from a
flag, which is correct; the docs then leave the header set to the operator, which is where people get it
wrong. Ship the exact header set — `Access-Control-Allow-Origin` (allowlist), `-Methods: POST, OPTIONS`,
`-Headers: Authorization, Content-Type, X-Dapr-*` — and refuse to start if the configured origin is `*`.

#### CLI

```
dapr workflow show --instance-id wf-8f3c... \
     --codec-endpoint https://codec.internal.acme.example/prod-eu
```

Gated on the history read API existing. Until then, `dapr workflow get` can route the plaintext
properties from `GetWorkflow` through the same endpoint, which is a smaller but immediately useful
version of the same thing.

#### The daprd-local convenience API, and why it is deny-by-default

```
POST /v1.0-alpha1/workflow/payloads/decode
```

daprd has the key material, so it *can* decode. For a single-tenant operator who just wants
`dapr workflow get` to work, this is the shortest path. It is also a decryption oracle inside every
sidecar, which is the opposite of what the standalone server exists to provide. Therefore: alpha, behind
the feature gate, listed as its own name in the API allowlist so it can be denied while the codec stays
on, and **absent from the default allowlist**. The docs must lead with the standalone server and present
this as the single-tenant shortcut it is.

### 4.5 Failure-path scrubbing

This is the hardest part, because the leaking strings come from arbitrary user code. It is also where
the largest concrete win is available, because Dapr currently does something strictly worse than it
needs to.

#### The verified leak

`durabletask-go/task/executor.go:117-120` records an activity failure as:

```go
FailureDetails: &protos.TaskFailureDetails{
    ErrorType:    fmt.Sprintf("%T", err),
    ErrorMessage: fmt.Sprintf("%+v", err),
},
```

`%+v` is the maximally verbose formatting verb. On a wrapped error it renders the entire chain; on a
`github.com/pkg/errors` value it renders a full stack trace. Whatever an activity author put in an error
string — a row, a field, an identifier — goes into history verbatim, and the choice of `%+v` over `%v`
is invisible to that author. The same construction appears at `executor.go:137`, and panics take a
similar path at `executor.go:100`.

`TaskFailureDetails` (`api/protos/orchestration.pb.go:376-386`) carries `ErrorType`, `ErrorMessage`,
`StackTrace`, a recursive `InnerFailure`, and `IsNonRetriable`. All of it is signed into the history
chain (`historysigning/attestation.go:93-125`) and re-exported over the management API
(`pkg/api/universal/workflow.go:115-118`).

#### Three layers, in order of leverage

**Layer 1 — treat failure attributes as codec payloads.** Structurally adopt Temporal's answer. Add an
`encoded_attributes` field to `TaskFailureDetails`; when the codec is active, move `errorMessage`,
`stackTrace`, and the entire `innerFailure` chain into a single encoded payload and blank the plaintext
fields. This is exactly `EncodeCommonAttributes` and exactly `Failure.encoded_attributes`.

Two deliberate divergences from Temporal:

- **Default it on** when a codec is configured. Temporal ships this off by default, which is why the
  caveat exists in its docs at all. A protection that must be discovered in a caveat is a protection
  most deployments will not have.
- **Keep `errorType` and `isNonRetriable` in plaintext**, because retry policy and terminal-vs-transient
  classification must work in a sidecar that cannot decode. The residual leak is real and should be
  stated in the docs, not buried: a type name like `InvalidSocialSecurityNumberFormatError` leaks the
  data class, and occasionally more. Advise generic exported error types at activity boundaries.

**Layer 2 — bound and normalize before recording.** Independent of any codec, and worth filing on its
own:

- Replace `fmt.Sprintf("%+v", err)` with `err.Error()` at `executor.go:119` and `:137`. Make the verbose
  form an explicit opt-in on the worker. This is a one-line change that strictly reduces what reaches
  history, and I would file it whether or not the rest of this proposal is accepted.
- Cap `errorMessage` and `stackTrace` length at a configurable ceiling, truncating with a marker. Long
  error strings are disproportionately the ones that embed payload dumps.
- Cap `innerFailure` depth. `historysigning/attestation.go:42` already defines
  `maxFailureRecursionDepth = 32` for the verifier; the recorder should share it.

**Layer 3 — a deny-pattern scrubber, labelled honestly.** A configurable pattern set applied to
`errorMessage` and `stackTrace` before they enter history, replacing matches with `<redacted:name>`.

```yaml
      failureScrubbing:
        patterns:
          - { name: pan,   regex: '\b(?:\d[ -]*?){13,19}\b' }
          - { name: email, regex: '[\w.+-]+@[\w-]+\.[\w.]+' }
        maxMessageBytes: 4096
```

State plainly what this is: **pattern matching on arbitrary text is not a security control.** It is a
seatbelt for the common cases, it will have false negatives on anything it was not written for, and a
deployment that relies on it as its only protection is misconfigured. It is worth shipping because it
catches the accident that a code review missed, and worth documenting in exactly those terms so nobody
treats it as a boundary.

#### The residual leak, stated without hedging

Layers 1–3 bound what reaches *history*. They do not bound what a developer writes:

- An activity that does `log.Printf("lookup failed for %s", ssn)` writes to the application's stdout.
  Nothing in this proposal touches application logs, and nothing can.
- An activity that returns payload-derived data in a *success* output governed by a `passthrough` rule
  leaks by policy, correctly configured. The policy is the control; the codec only enforces it.
- Distributed trace spans and their attributes are outside this proposal's scope entirely, and are a
  well-known payload-leak channel.
- An error value that both carries data and drives control flow (`errors.Is` on a wrapped error holding
  a business identifier) forces a genuine trade between debuggability and confidentiality that no
  mechanism resolves. Encoded attributes make the debugging path a decode request rather than a glance
  at the console, which is the right trade but is a real cost.

A codec bounds where data goes. It cannot bound what developers put in it. Any proposal claiming
otherwise is overselling.

### 4.6 Interaction with history signing — the sharpest open design question

Dapr has something Temporal does not, and it constrains this design in a way worth working out in the
proposal rather than discovering in review.

`signing/sign.go:58-80` marshals each new event with `historysigning.MarshalEvent`, stores those bytes
via `SetMarshaledNewHistory`, and signs them into a hash chain. So **the signature covers exactly the
persisted bytes.**

That yields a clean answer for the chain:

```
plaintext event
  → codec.Encode(payload fields)          ← this proposal
  → historysigning.MarshalEvent
  → Sign  (chain covers ciphertext)
  → persist
```

Encode **before** marshal. The chain then covers the ciphertext, which means a verifier needs no key to
check integrity. Tamper detection, the `IsTamperMarker` path (`wfengine/state/state.go:1068`) and
`VerifyChain` (`state.go:1187`) all keep working in a process that cannot decrypt. That is the right
property and it falls out for free from the existing ordering.

The unresolved half is the **activity attestation**. `signing/attach.go:104-118` builds an
`ActivityAttestationInput` from the plaintext `Input`, `Output`, and `FailureDetails`, and
`historysigning.CanonicalInput` / `CanonicalSuccessOutput` (`attestation.go:57-72`) digest the NFC-
normalized plaintext. This runs in the sidecar at activity completion, before any codec would apply.
Consequences:

- The `ioDigest` is over plaintext. That is arguably *correct* — the attestation asserts what the
  activity actually returned, which is a plaintext claim.
- But it means a verifier without a key can verify the chain and **not** the attestation. Two integrity
  properties with two different trust requirements is a subtle thing to document and a subtle thing for
  operators to reason about.
- Alternatively, digesting ciphertext would make attestation key-free but would break the property that
  the attestation binds the activity's actual return value, since ciphertext is nondeterministic across
  encodings of the same plaintext.

I do not think this has a clean answer and I am not going to pretend it does. It is listed as open
question §9.1 and it is the item most likely to reshape the design in review.

---

## 5. What application code looks like

Unchanged. This is the payoff, and it is the same payoff as the delegated-identity proposal's §5.

```csharp
public async Task<CustomerRecord> Run(LookupRequest req, WorkflowActivityContext ctx)
{
    return await _crm.GetCustomerAsync(req.CustomerId);
}
```

No codec in the signature. No key. No `[Encrypted]` attribute required for correctness — the policy
defaults to encode, so this activity's return value is encrypted at rest whether or not anyone thought
about it. The optional `sensitive: true` hint exists, but forgetting it costs nothing, because
forgetting it cannot make things less safe (§4.3).

That last property is the whole design. Compare it to the annotation-based alternative, where this
identical code leaks a customer record because nobody wrote one line.

---

## 6. Configuration and feature gating

Fully additive, off by default. With `WorkflowPayloadCodec` disabled, a `payloadCodec` block fails
Configuration validation at load with an actionable error rather than being silently ignored — the same
posture the delegated-identity proposal takes for `onBehalfOf`.

Enabling the codec on a store that already holds plaintext history does **not** re-encrypt it. Existing
instances remain readable because decode is a no-op on unencoded payloads (the envelope is
self-describing, matching the `Decode` behavior in Temporal's own sample, which passes through anything
not carrying its encoding tag). Migration is therefore forward-only and requires no downtime, at the
cost of a mixed store. Say so in the docs; the alternative — a re-encryption pass over live history —
is not worth building.

---

## 7. Security considerations

### 7.1 The sidecar becomes a decryption oracle

daprd holds the DEK for every instance it is currently running. A compromised sidecar can read every
payload it can reach. Mitigations: the daprd-local decode API is deny-by-default (§4.4); component
scoping already limits which apps can reach which crypto component; DEKs are per-instance and held only
while the instance is loaded; and the KEK never leaves the vault.

Stated plainly, as the delegated-identity proposal states its equivalent: this is a real increase in
what a compromised sidecar yields, and it is justified only because the alternative today is plaintext
history readable by anyone with state store access, which is strictly worse.

### 7.2 Key loss is data loss *and* a stuck workflow

This is the non-obvious one. Losing the KEK does not merely make history unreadable — it makes in-flight
instances **unreplayable**, and an unreplayable workflow is a wedged workflow, not just a lost record.
Requirements that follow:

- The vault must retain every key version that any live-or-retained instance was encoded under. Rotation
  is safe (the envelope names its key), but *deletion* of an old key version destroys workflows.
- Retention policy (`WorkflowStateRetentionPolicy`) and key retention must be reconciled by the
  operator. The docs must say this, and `dapr` should ideally warn when a decode fails with
  key-not-found rather than surfacing a generic error.
- This is a new operational failure mode with no analogue in Dapr today, and it deserves its own docs
  page rather than a bullet.

### 7.3 Nondeterminism and replay

Encryption is nondeterministic by design. Encode must therefore never run on the orchestrator's
deterministic path — only at the persistence boundary, where a differing nonce cannot change workflow
outcomes. §11.4 tests this directly.

### 7.4 The codec server is a high-value target

It exists to turn a request into plaintext. Deny-by-default policy, mandatory audit, decode-only by
default, no wildcard CORS, and mTLS or OIDC on every request (§4.4). It should also be rate-limited per
caller identity, because an unlimited decode endpoint is an exfiltration tool with a nice API.

### 7.5 Logging and telemetry

No decoded payload may appear in daprd logs, traces, or metrics at any verbosity, including debug. This
needs a wrapper type that refuses to marshal, not a code-review convention — the same requirement, for
the same reason, as the delegated-identity proposal's §7.5.

---

## 8. Alternatives considered

**Do nothing; tell people to pass pointers, not blobs.** The strongest alternative, and it is genuinely
good advice independent of this proposal: hand the workflow an identifier and let the activity fetch the
payload. It keeps history small, replay fast, and sensitive content out of the durable log *by
construction*. It fails when the pointer's referent must outlive the workflow, when the fetch is not
idempotent, or when the identifier is itself sensitive. It also pushes the problem into every
application rather than solving it once. Recommended as the interim pattern (Appendix B) and as
permanent good practice, not as a substitute.

**Extend the existing state-store encryption to cover the actor path.** Superficially the cheapest fix
for §2.2 — add the `pkg/encryption` calls to `pkg/actors/state/state.go` and workflow history is
encrypted. It is the wrong shape: AES-GCM only, hardcoded (`encryption.go:190`); keys as hex strings from
a secret store, so no KMS or HSM; base64 expansion on every value (`state.go:52`), which matters against
a 4 MiB ceiling; global package-level registration by store name (`state.go:22`), so it is all-or-nothing
by construction; and no decode path for anything. It would close the "history is plaintext" hole while
foreclosing every other requirement. **However** — it is a small change with real value, and if the full
proposal stalls in review, this is the fallback worth shipping alone, clearly labelled as a floor rather
than a solution.

**A codec in every SDK (Temporal's model, ported).** Genuinely tempting, and it is the only design that
protects against a compromised sidecar. Five implementations, a normative cross-language envelope
spec, key material back in application processes in direct contradiction of the crypto building block's
stated purpose, and rework of three existing sidecar-side features (§4.1). Reserved as a phase-3 escape
hatch rather than the default.

**Rely on state store native encryption at rest.** Redis, Postgres, and Cosmos all offer it. It defends
against a stolen disk and nothing else: the store operator, anyone with a query console, and every
backup consumer still see plaintext. It is not a substitute for application-controlled keys, which is
the whole point of a customer-managed-key requirement.

**A codec that is a middleware pipeline stage.** Middleware is pipeline-scoped and statically
configured, and runs on the service invocation path, which is the wrong side of the sidecar for
workflow history persistence. Same reason the delegated-identity proposal rejects
`middleware.http.oauth2clientcredentials`.

---

## 9. Open questions

### 9.1 Attestation over plaintext versus ciphertext

§4.6. The chain signature can cleanly cover ciphertext; the activity attestation's `ioDigest` cannot
without giving up its meaning. The result is two integrity properties with two different key
requirements. **Proposed resolution:** ship with attestation over plaintext, document the asymmetry
precisely, and treat "key-free attestation verification" as a separate future problem. I flag this as
the question most likely to change the design.

### 9.2 Cross-app workflows and propagated history

`dapr/proposals/20250320-RS-multi-app-workflows.md` exists, and `PropagatedHistory` is signed and
verified across app boundaries (`orchestrator/signing/propagation.go:53,95`;
`wfengine/state/state.go:229`). If app A and app B run under different codec policies, whose codec
applies to a propagated chunk? Options: the producing app's (and B stores an opaque blob it cannot
read), the consuming app's (requires re-encoding, which breaks the signature), or a trust-domain-scoped
policy above both. No clean answer yet; this needs its own analysis before phase 2 ships.

### 9.3 Replay cost against a remote KMS

Every replay decodes every history event. With a remote KMS that is a per-event round trip unless
something is cached. Envelope encryption fixes it — unwrap the DEK once per instance load, then decrypt
locally — but only if the whole instance shares one DEK, which weakens per-activity key separation. A
per-activity key would be cleaner and would cost a KMS call per event. **Proposed resolution:**
per-instance DEK by default, per-rule DEK as an option, with the trade documented. Needs a benchmark
before it is settled.

### 9.4 Does the codec apply to `wait_for_external_event` inputs?

`EventRaisedEvent.Input` is listed in §4.1's scope, but external events arrive from outside the workflow
and their sensitivity is often governed by a different policy than the workflow's own activities.
Probably yes, uniformly; flagged because "probably" is not "verified."

### 9.5 Pluggable-codec performance budget

A tier-2 codec over gRPC (`pkg/components/pluggable/`) adds a round trip per encode and per decode. For
a workflow saving a handful of events per turn that is fine; for a wide fan-out it may not be. Batch
the whole event set into one `Encode` call — the contract in §4.2 takes a slice for exactly this reason
— and measure before committing.

### 9.6 Does the SDK `sensitive` hint need a wire representation?

If the hint travels from the app to daprd, it needs a field on the work-item protocol. If it is instead
resolved SDK-side into something the sidecar reads, it needs a different mechanism. **Unverified:** I did
not trace whether the existing work-item protos have a suitable extension point.

---

## 10. Implementation plan

### Phase 0 — the standalone fixes, filed separately

These are independently correct and should not wait on the rest.

- Replace `fmt.Sprintf("%+v", err)` with `err.Error()` in `durabletask-go/task/executor.go:119,137`;
  add an opt-in verbose mode. (§4.5 layer 2.)
- Cap `errorMessage` / `stackTrace` length and `innerFailure` depth at record time.
- Documentation fix: state explicitly that state-store encryption does **not** cover actor state or
  workflow history. This is the highest-value change in the whole document, because the current silence
  causes people to believe they have a protection they do not have.

### Phase 1 — the codec, tier 1

**Scope**

- Codec application points in `pkg/runtime/wfengine/state/state.go` (`GetSaveRequest`,
  `loadWorkflowStateOnce`), field-level per §4.1, ordered before `MarshalEvent` per §4.6.
- `dapr.io/enc/v1` envelope via the existing `crypto` building block; per-instance DEK.
- `Configuration.spec.workflow.payloadCodec` policy per §4.3, `default: encode`, glob matching.
- Failure-attribute encoding per §4.5 layer 1, including the `encoded_attributes` field on
  `TaskFailureDetails` (a `durabletask-go` proto change).
- Feature gate `WorkflowPayloadCodec`.
- `instanceMetadata` scope, which is what makes the delegated-identity proposal's §4.2 invariant
  implementable (§3).

**Acceptance criteria**

- Raw state store inspection finds no plaintext payload for any encoded instance, before and after
  suspend/resume, and after replay.
- The §5 code sample is unchanged between codec-off and codec-on.
- Signature chain verification succeeds in a process with **no** key access.
- A workflow started before the codec was enabled continues to replay and complete correctly.
- Key rotation: an instance encoded under key version N replays after the vault's primary moves to N+1.
- Every row of the §4.3 policy table produces the documented outcome, including the tighten-only
  composition rule.

**Deliberately excluded:** the decode service. Phase 1 must be independently useful and independently
reviewable, exactly as the delegated-identity proposal's phase 1 excludes workflow integration.

### Phase 2 — the decode service

Blocked on a **workflow history read API**, which is a separate proposal (§4.4) and should be filed
first.

**Scope**

- Standalone Dapr Codec Server: protocol per §4.4, mTLS/SVID + OIDC, deny-by-default policy, mandatory
  audit, decode-only default, allowlist CORS.
- `dapr workflow show --codec-endpoint`.
- Routing of `GetWorkflow`'s plaintext properties (`pkg/api/universal/workflow.go:98-118`) through the
  codec, so the management API stops handing payloads and stack traces to every caller with `workflow`
  access.
- The daprd-local `/v1.0-alpha1/workflow/payloads/decode` convenience API, feature-gated, separately
  allowlisted, absent from the default allowlist.

**Acceptance criteria**

- A console with no key material renders a full encoded history through the codec server.
- Every decode produces exactly one audit event naming caller, instance, and payload count.
- An unconfigured codec server denies every request.
- A per-payload `redacted` result renders as structure-without-content in the console rather than an
  error.
- `/encode` is absent unless explicitly enabled; a wildcard CORS origin refuses to start.

### Phase 3 — breadth

- The `codec` component type (§4.2 tier 2), including a pluggable-component path, and with it the
  large-payload offload pattern and the `/download` endpoint.
- SDK-side sealed payloads (§4.1) for threat models excluding the sidecar.
- Cross-app propagated-history policy (§9.2).
- Failure scrubbing layer 3 (§4.5).
- Metrics, dashboards, security review.

### Sequencing note

Phase 0 should be filed today and merged independently. Phase 1 stands on its own — it closes a hole
that currently has no mitigation at all — and gives reviewers something concrete before they are asked
to accept a new HTTP service into the project. Bundling phases 1 and 2 roughly doubles the surface a
reviewer must accept at once, which is how good proposals stall.

---

## 11. Testing strategy

### 11.1 Component conformance

Extend the existing `components-contrib` crypto conformance suite with codec-shaped cases: encode/decode
round-trip across a key rotation, decode of a payload encoded under a since-rotated key, decode failure
when the key version has been deleted, and pass-through of unencoded payloads.

### 11.2 The invariant test (shared with the delegated-identity proposal)

Start a workflow whose activities return known sentinel strings; drive it through suspend, resume,
replay, and completion; then **scan the raw state store bytes** for those sentinels, for anything
matching a JWT structure, and for the known failure-message contents. This is the enforcement mechanism
for both this proposal's confidentiality property and the delegated-identity proposal's §4.2 persistence
invariant, and it should be one suite (§3).

### 11.3 Signing interaction

Verify the full chain in a process constructed with **no** access to the crypto component. Confirm
`VerifyChain` succeeds, `IsTamperMarker` behaves correctly, and that flipping one ciphertext byte is
detected. Then confirm that attestation `ioDigest` verification correctly *fails* without a key, and
document that as expected behavior rather than a bug (§4.6, §9.1).

### 11.4 Replay determinism

Assert that encode never runs on the orchestrator's deterministic path; that two runs producing
different nonces produce identical workflow outcomes; and that a replay after a process restart, with a
cold DEK cache, reaches the same terminal state as a warm one.

### 11.5 Policy

Table-driven over the §4.3 rule grammar: ordering, first-match-wins, glob edge cases, `default: encode`
on omission, and — the important one — that an SDK `sensitive` hint can promote `passthrough` to
`encode` and **cannot** do the reverse under any configuration.

### 11.6 Adversarial

Attempt to reach the daprd-local decode API when it is denied by allowlist. Attempt to decode another
tenant's instance through the codec server. Attempt to start a codec server with `Access-Control-Allow-Origin: *`.
Confirm no decoded payload appears in logs at debug verbosity. Confirm a decode attempt against a
deleted key version produces an actionable error rather than a wedged instance without explanation.

---

## 12. Observability

- `dapr_workflow_codec_encode_total{component,result}`
- `dapr_workflow_codec_decode_total{component,result}`
- `dapr_workflow_codec_latency_seconds{component,operation}`
- `dapr_workflow_codec_bytes{operation}` — encoded size versus plaintext, to make envelope overhead
  against the 4 MiB ceiling visible before it bites
- `dapr_workflow_codec_passthrough_total{workflow,activity}` — **the number to watch.** A high
  passthrough rate against a workload believed to be fully encrypted is the leading indicator of an
  over-broad carve-out rule.
- `dapr_codecserver_decode_total{caller,namespace,result}` on the standalone server.

Trace spans for codec operations carry component, operation, and byte counts. **Never plaintext, never
ciphertext.**

---

## 13. Documentation impact

- **A correction, first.** The state-encryption how-to must state that the feature applies to the state
  management API and does **not** cover actor state or workflow history. This is the single most
  valuable line in the whole proposal, and it should be merged before any code.
- New concept page: what is durable in a workflow, and what that means for sensitive data. Framed around
  §1's observation that anything crossing an activity boundary is a durable artifact.
- New how-to: encrypting workflow payloads.
- New operations page: **key custody and workflow recoverability** (§7.2). The failure mode — losing a
  key wedges live workflows, not just old records — has no analogue elsewhere in Dapr and will surprise
  people.
- Codec server deployment guide, leading with the deny-by-default policy.
- An explicit cross-reference to the delegated identity docs stating the §3 boundary, on both pages.

---

## 14. Success criteria

1. Workflow history contains no plaintext business payload for any instance governed by an `encode`
   rule, verified by raw state store inspection.
2. A developer who writes an ordinary activity and thinks about none of this still gets encrypted
   history, because the default is encode.
3. An operations console renders a complete workflow history, including failure messages, while holding
   no key material — and every such read is audited.
4. Activity and workflow code is unchanged between codec-off and codec-on.
5. Signature chain verification works with no key access.
6. Keys live in a customer-controlled KMS or HSM and are rotatable without re-encrypting history.
7. `errorMessage` and `stackTrace` are encoded by default when a codec is configured, rather than by
   opt-in.

---

## What this does NOT fix

Stated bluntly, because a proposal that only lists its wins is not a design document.

1. **Plaintext still crosses the app ↔ daprd boundary.** Loopback inside the pod under the Kubernetes
   injector default, and all interfaces under the self-hosted default. Not encrypted in flight by this
   proposal.
2. **No defense against a compromised sidecar or a compromised application.** Both hold plaintext by
   necessity. Sealed payloads (phase 3) address the sidecar case at real cost; nothing addresses the app.
3. **Application logs, stdout, and app-side telemetry are untouched.** An activity that logs a customer
   record has leaked it, and no history codec can intervene.
4. **Distributed trace spans and baggage are out of scope entirely**, and are a well-known payload leak
   channel.
5. **No field-level encryption within a payload.** Deliberately rejected (§4.3). Tier-2 tokenization
   codecs are the answer for anyone who genuinely needs it.
6. **The 4 MiB ceiling gets slightly worse**, not better. Envelope overhead is small but nonzero, and it
   lands on a limit some workloads already brush. Tier 2's offload codec is the real fix and it is
   phase 3.
7. **Key loss destroys data and wedges live workflows** (§7.2). This proposal creates that failure mode;
   it does not solve it. Key custody becomes an availability concern, not just a confidentiality one.
8. **A misconfigured policy still leaks.** `default: passthrough` or a wildcard carve-out disables
   everything here. The metric in §12 exists to make that visible; it cannot prevent it.
9. **`errorType` remains plaintext by design**, so error type names can leak the data class.
10. **Pattern-based failure scrubbing is not a control** (§4.5 layer 3). Best-effort, with false
    negatives, by construction.
11. **No cross-language parity with Temporal for sidecar-excluding threat models** until phase 3, and
    even then with worse ergonomics.
12. **Retention is not addressed** — because it is already shipped
    (`WorkflowStateRetentionPolicy`, `pkg/apis/configuration/v1alpha1/types.go:191-215`). Any gap
    analysis still listing history TTL as missing is out of date.
13. **The decode service is blocked on an API that does not exist.** There is no workflow history read
    RPC in `dapr/dapr/proto/runtime/v1/workflow.proto`. Until one lands, "key-free decode for tooling"
    has almost nothing to decode.

---

## Appendix A — anticipating the main objection

Expect: *"Dapr already has state store encryption. Just turn it on for the actor state store."*

The answer is that this does not work, and the reason it does not work is not obvious from the docs.
State-store encryption is applied in the state building block's API layer only — `pkg/api/grpc/grpc.go`,
`pkg/api/http/http.go`, `pkg/api/universal/state_query.go`. Workflow history is written by
`pkg/actors/state/state.go`, which calls the contrib store directly and never imports `pkg/encryption`.
There is not a single non-test occurrence of `encrypt` under `pkg/actors/` or `pkg/runtime/wfengine/`.

A reviewer who believes otherwise should be invited to run that grep before the discussion continues,
because everything else in this proposal follows from it. And whatever happens to the rest of the
document, **the documentation fix in phase 0 should merge**: people are currently making deployment
decisions on the belief that a protection exists which does not.

The secondary objection — *"a codec belongs in the SDK, that's how Temporal does it"* — is answered in
§4.1. Temporal puts the codec in the client because in Temporal the server is the untrusted party. Dapr
has no such server. Copying the placement copies the answer to a different question.

## Appendix B — the interim pattern

Until this ships, in descending order of effectiveness:

1. **Pass pointers, not blobs.** Hand the workflow an identifier; let the activity fetch the payload from
   a store you already secure. This keeps sensitive content out of the durable log by construction, and
   it remains good practice afterward.
2. **Encrypt inside the activity.** Call the Dapr crypto API (`/v1.0-alpha1/crypto/{component}/encrypt`)
   on the value before returning it, and decrypt on the way in. Roughly fifteen lines. You get
   KMS-backed envelope encryption and correct key handling; you lose readable history entirely, since
   nothing can decode it for a console.
3. **Return generic errors from activities.** Given `executor.go:119`'s `%+v`, assume anything in an
   error value reaches durable storage and the management API. Wrap with a generic message at the
   activity boundary and log the detail locally.
4. **Lock down the management API.** `GetWorkflow` returns `dapr.workflow.input`, `output`,
   `custom_status`, `failure.error_message` and `failure.stack_trace` in plaintext
   (`pkg/api/universal/workflow.go:98-118`). Treat `workflow` API access as equivalent to read access on
   every payload the workflow touched, and scope it accordingly.
5. **Set `--dapr-listen-addresses` to loopback explicitly** in self-hosted deployments, where the default
   is all interfaces.

Documenting this honestly strengthens the proposal: it shows the problem is real enough that people are
already working around it, and it shows what the workarounds cost.
