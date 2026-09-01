# Verification report

Two documents fact-checked against primary sources, 2026-09-01.

- **A** = `dapr-workflow-vs-temporal.md`
- **B** = `dapr-delegated-identity-proposal.md`

## Method and evidence provenance

Two classes of evidence appear below, and they are marked differently on purpose.

**Source-code evidence** was obtained by shallow-cloning the actual repositories and reading/grepping the working tree, not by fetching prose about them. Clones and pinned commits:

| Repo | Commit read | Date |
|---|---|---|
| `dapr/dapr` | `12463d2bfd849eabaef5c2873b314d5d74f861e9` (master) + tags `v1.16.0`, `v1.17.0`, `v1.18.3` | 2026-09-01 |
| `dapr/durabletask-go` | `18cd4b5a26a5d53f127a12dd7aa2d496314f3de6` (main) | 2026-08-26 |
| `dapr/python-sdk` | `e4ad1818079c5089814e4d1610b585286d28b98f` (master) + tag `v1.18.3` | 2026-08-17 |
| `dapr/components-contrib` | full-tree sparse checkout, master | 2026-09-01 |
| `dapr/proposals` | `9ca89581009e7dc7827bd0c619c05b8264b95512` | 2026-03-25 |
| `dapr/dapr-agents` | `a383dd47b11458783123c4e703cdc75ee661e756` | 2026-08-30 |

For those rows the URL column gives the canonical GitHub path to the file I read. The bytes came from the clone at the commit above, not from that web page.

**Web evidence** (docs.dapr.io, docs.temporal.io, modelcontextprotocol.io, rfc-editor.org, learn.microsoft.com, agentgateway.dev) was fetched live. Every such URL in the table below returned 200 and I read its contents.

---

## Findings table

| # | Claim (short) | Doc + section | Verdict | Primary source | Note |
|---|---|---|---|---|---|
| 1 | Dapr Workflow has no per-activity timeout of any kind | A §1 | **CONFIRMED** | [`durabletask-go/task/activity.go`](https://github.com/dapr/durabletask-go/blob/main/task/activity.go) (`callActivityOptions` = rawInput, retryPolicy, targetAppID, targetAppNamespace, propagationScope); [`python-sdk` v1.18.3 `dapr_workflow_context.py`](https://github.com/dapr/python-sdk/blob/v1.18.3/ext/dapr-ext-workflow/dapr/ext/workflow/dapr_workflow_context.py) | Stronger than the doc claims. The **wire protocol** has no timeout field either: `ScheduleTaskAction` in `api/protos/orchestrator_actions.pb.go` carries only `Name`, `Version`, `Input`, `TaskExecutionId`, `HistoryPropagationScope`. No SDK could express an activity timeout without a proto change. That is positive evidence of a design boundary, not just absence. |
| 2 | No activity heartbeat mechanism | A §1 | **CONFIRMED** | `dapr/durabletask-go` @ `18cd4b5`, full-repo grep | Case-insensitive `heartbeat` across every `.go` file in the repo: **zero matches**, tests included. |
| 3 | `RetryPolicy.retry_timeout` bounds total time across retries, cannot cancel a hung attempt | A §1 | **CONFIRMED** | [`durabletask-go/task/activity.go:44`](https://github.com/dapr/durabletask-go/blob/main/task/activity.go) and [`task/orchestrator.go:575-590`](https://github.com/dapr/durabletask-go/blob/main/task/orchestrator.go) | Field comment: *"Total timeout across all the retries performed."* Enforcement is in `computeNextDelay`: `isExpired = currentTimeUtc.After(firstAttempt.Add(policy.RetryTimeout))`. It is evaluated **only when deciding whether to schedule another retry**, measured from `firstAttempt`. It has no channel to a running attempt. The doc's reasoning is exactly right. |
| 4 | `wait_for_external_event` does take a timeout (the asymmetry) | A §1 | **CONFIRMED** | [`python-sdk workflow_context.py:184-198`](https://github.com/dapr/python-sdk/blob/master/ext/dapr-ext-workflow/dapr/ext/workflow/workflow_context.py); [`durabletask-go task/orchestrator.go` `WaitForSingleEvent`](https://github.com/dapr/durabletask-go/blob/main/task/orchestrator.go) | Python: `timeout: Optional[Union[datetime, timedelta]] = None`. Go: `WaitForSingleEvent(eventName string, timeout time.Duration)`. |
| 5 | Temporal has exactly four activity timeouts | A §1 | **CONFIRMED** | https://docs.temporal.io/encyclopedia/detecting-activity-failures | Page enumerates precisely schedule-to-start, start-to-close, schedule-to-close, heartbeat. |
| 6 | 4 MiB default `--max-body-size`, bounds a workflow/activity dispatch | A §3 | **CONFIRMED** | [`dapr/pkg/runtime/config.go:63`](https://github.com/dapr/dapr/blob/master/pkg/runtime/config.go) `DefaultMaxRequestBodySize = 4 << 20`; [`cmd/daprd/options/options.go:159`](https://github.com/dapr/dapr/blob/master/cmd/daprd/options/options.go); https://docs.dapr.io/developing-applications/building-blocks/workflow/workflow-features-concepts/ | Flag name current; the **old** name `--dapr-http-max-request-size` is `MarkDeprecated`. Docs confirm the workflow binding verbatim. **Missing nuance:** the limit is not a hard cliff — dapr stalls the workflow at **95%** of the cap with `PAYLOAD_SIZE_EXCEEDED` and it resumes if the cluster is rolled to a larger value (`tests/integration/suite/daprd/workflow/loadbalance/stalled/maxbodysize.go`; metric `runtime/workflow/activity/payload/size_ratio`). |
| 7 | Built on Durable Task Framework, event-sourced history, deterministic replay | A §preamble | **CONFIRMED** | https://docs.dapr.io/developing-applications/building-blocks/workflow/workflow-architecture/ | Docs: engine "implemented using the `durabletask-go` framework library"; history is "an append-only log". Determinism constraints confirmed on the features-concepts page. |
| 8a | Workflow history persists through the actor state store | A §4 | **CONFIRMED** | https://docs.dapr.io/developing-applications/building-blocks/workflow/workflow-architecture/ ; [`pkg/runtime/wfengine/backends/actors/actors.go:1266`](https://github.com/dapr/dapr/blob/master/pkg/runtime/wfengine/backends/actors/actors.go) | Docs: state persisted in "the configured actor state store". Traced: orchestrator actor → `astate.TransactionalStateOperation(...)`. |
| 8b | **…therefore enabling state-store encryption encrypts workflow history at rest** | A §4 | **REFUTED** | [`pkg/runtime/processor/state/state.go:84,105,140,158`](https://github.com/dapr/dapr/blob/v1.18.3/pkg/runtime/processor/state/state.go) (decisive); [`pkg/actors/state/state.go:248`](https://github.com/dapr/dapr/blob/master/pkg/actors/state/state.go) | **Corrected 2026-09-01 — my original CONFIRMED was wrong.** I established that history reaches the actor state store, then *inferred* that the encryption layer sits on that path. It does not. See §C11. Verified identical at tag `v1.18.3` and on master. |
| 9 | Encryption specifics: AES-GCM, 128/192/256, keys from secret store, primary/secondary rotation, **`secretKeyRef.name` appended to the state key** | A §4 | **PARTIALLY CORRECT** | [`dapr/pkg/encryption/state.go:44-55`](https://github.com/dapr/dapr/blob/master/pkg/encryption/state.go) and [`encryption.go:38,186-203`](https://github.com/dapr/dapr/blob/master/pkg/encryption/encryption.go); https://docs.dapr.io/developing-applications/building-blocks/state-management/howto-encrypt-state/ | Cipher, key sizes, secret-store sourcing and primary/secondary rotation: all confirmed. **The last clause is wrong.** The key name is appended to the **value**, not the state key: `sEnc := b64(enc) + "\|\|" + keys.Primary.Name`, and the function's own comment reads *"will append the name of the key to the value for later extraction."* Notably, docs.dapr.io says "appends the secretKeyRef.name field to the end of the actual state key" — so the doc faithfully reproduces an error in Dapr's own documentation. The code is authoritative. Undocumented extra: the key is `hex.DecodeString`d, so it must be hex-encoded. |
| 10 | Temporal Data Converter / Payload Codec / Codec Server, `/decode` `/encode` `/download`, failure messages not codec-encoded by default | A §4 | **CONFIRMED** | https://docs.temporal.io/production-deployment/data-encryption | All three endpoints confirmed, including `/download`. Caveat verbatim: *"Failure messages and call stacks are not encoded as codec-capable Payloads by default; you must explicitly enable encoding these common attributes on failures."* CORS and access-control caveats also confirmed. The strongest-sourced section of doc A. |
| 11 | Temporal has patching + worker versioning; **"Dapr's story here is thinner… mitigation is to avoid needing it"** | A §2, summary table | **REFUTED** | https://docs.dapr.io/developing-applications/building-blocks/workflow/workflow-versioning/ ; [`durabletask-go/task/orchestrator.go:731`](https://github.com/dapr/durabletask-go/blob/main/task/orchestrator.go) `func (ctx *WorkflowContext) IsPatched(patchName string) bool`; [`python-sdk v1.18.3 dapr_workflow_context.py:169`](https://github.com/dapr/python-sdk/blob/v1.18.3/ext/dapr-ext-workflow/dapr/ext/workflow/dapr_workflow_context.py) `def is_patched`; `workflow_runtime.py:253,393` `register_versioned_workflow` / `@versioned_workflow` | **The single largest error in either document.** Temporal half is correct (https://docs.temporal.io/develop/go/versioning). The Dapr half is not. Dapr v1.18 ships **both** mechanisms Temporal has, with a dedicated docs page: patch-based versioning (`IsPatched()` / `is_patched()`, history-tracked) and named workflow versions (.NET source generators, Go `AddVersionedWorkflow()` with `isLatest`, Python `@wfr.versioned_workflow()` with `is_latest`). Runtime support is in `v1.18.3` (`state.WorkflowVersion` in the actors backend; `WorkflowVersionNotAvailableAction` in the protos). There is also an accepted design in `dapr/proposals/20251028-BRS-workflow-versioning.md` (Whit Waldo, "Workflow Patching and Versioning") which explicitly says *"Temporal implements both of them"* and unifies PRs #82 and #92. The features-concepts page the doc cites elsewhere directs readers to "use the workflow versioning concepts described in the versioning guide to patch and introduce new named workflow versions." **`is_patched` sits ~100 lines below the `call_activity` the doc verified against, in the same file of the same release.** |
| 12 | At-least-once activity execution; idempotency required | A §1 | **CONFIRMED** | https://docs.dapr.io/developing-applications/building-blocks/workflow/workflow-features-concepts/ | Verbatim: engine "guarantees that each called activity is executed **at least once**"; recommends idempotent activity logic. |
| 13a | `DurableAgent` is a first-party agent-loop class (memory, tools, multi-agent) | A §5 | **CONFIRMED** | [`dapr-agents/dapr_agents/agents/durable.py:259`](https://github.com/dapr/dapr-agents/blob/main/dapr_agents/agents/durable.py) | `class DurableAgent(AgentBase)`; constructor takes `memory`, `tools`, `llm`, `pubsub`, `registry`, `execution`, `hooks`. Docstring: "Workflow-native durable agent runtime". |
| 13b | …with **SPIFFE-based per-agent cryptographic identity** | A §5, summary table | **REFUTED** | `dapr/dapr-agents` @ `a383dd4`, full-repo grep | Case-insensitive `spiffe` across the **entire repository** — Python, Markdown, YAML, everything: **zero matches**. `mtls`/`x509`/`svid` appear only in `README.md`. The SPIFFE identity is a property of the Dapr sidecar (one SVID per `app-id`, `spiffe://<td>/ns/<ns>/<app-id>`), not something `DurableAgent` ships or is aware of. If you run one agent per app-id you get per-agent identity **by deployment convention**, not by framework feature. |
| 13c | Temporal ships no equivalent agent loop | A §5 | **PARTIALLY CORRECT** | https://github.com/temporalio/sdk-python/blob/main/temporalio/contrib/openai_agents/README.md ; https://temporal.io/blog/announcing-openai-agents-sdk-integration | Temporal ships no agent-loop *class of its own*, which is the defensible reading. But `temporalio.contrib.openai_agents` is **in-repo, first-party, and GA since 2026-03-23**: Temporal supplies a `Runner` implementation that drives the OpenAI Agents SDK loop and makes every LLM and tool call an activity automatically. "Leaves the agent loop as application code, even where their marketing points at agents" is too strong for Temporal as of 2026. |
| 14a | Sentry is a CA issuing X.509 SVIDs, SPIFFE ID `spiffe://<td>/ns/<ns>/<app-id>` | B §2.1 | **CONFIRMED** | [`dapr/pkg/security/security.go:376`](https://github.com/dapr/dapr/blob/master/pkg/security/security.go) `expID := "/ns/" + ns + "/" + appID` | Exact form confirmed in code. |
| 14b | **1.16** added JWT-SVIDs + OIDC discovery (`/.well-known/openid-configuration`, `/jwks.json`); `--sentry-request-jwt-audiences` / `dapr.io/sentry-request-jwt-audiences` | B §2.1, Appendix A | **CONFIRMED** | `git ls-tree` on tags `v1.15.0` / `v1.16.0`; [`pkg/sentry/server/oidc/oidc.go:40,42`](https://github.com/dapr/dapr/blob/master/pkg/sentry/server/oidc/oidc.go); [`pkg/injector/annotations/annotations.go:81`](https://github.com/dapr/dapr/blob/master/pkg/injector/annotations/annotations.go) | `pkg/sentry/server/oidc/` and `pkg/sentry/server/ca/jwt/` are **absent at `v1.15.0` and present at `v1.16.0`**. Endpoint constants match exactly. Flag and annotation names match exactly, both present since `v1.16.0`. The version attribution is right. |
| 15a | **1.18** added per-audience token SVIDs in Sentry | B §2.1 | **CONFIRMED** | `git diff v1.17.0 v1.18.3 -- pkg/security/sentry.go`, [`pkg/security/sentry.go`](https://github.com/dapr/dapr/blob/master/pkg/security/sentry.go) | `resp.GetPerAudienceJwts()` and `spiffe.SVIDResponse.PerAudienceJWT` are added in that diff, absent at 1.17.0. Also new in the window: `Handler.FetchJWT(ctx, audience)` in `pkg/security/security.go`. |
| 15b | **1.18** shipped the `MCPServer` resource | B §2.1 | **CONFIRMED** | `git ls-tree` tags `v1.16.0`/`v1.17.0`/`v1.18.3`; [`pkg/apis/mcpserver/v1alpha1/types.go`](https://github.com/dapr/dapr/blob/master/pkg/apis/mcpserver/v1alpha1/types.go); [`dapr/proposals/20260304-CR-mcpserver.md`](https://github.com/dapr/proposals/blob/main/20260304-CR-mcpserver.md) (Samantha Coyle) | Zero `mcpserver` paths at 1.16 and 1.17; full CRD + `charts/dapr/crds/mcpservers.yaml` at `v1.18.3`. |
| 15c | **The `MCPServer` YAML sketch in §4.3** (`spec.transport`, `spec.url`, `spec.auth.clientCredentials{tokenUrl, clientId, clientSecret.secretKeyRef, scopes}`) | B §4.3 | **REFUTED** | [`pkg/apis/mcpserver/v1alpha1/types.go`](https://github.com/dapr/dapr/blob/v1.18.3/pkg/apis/mcpserver/v1alpha1/types.go) read at tag `v1.18.3` | Every structural element is wrong. Real shape: `spec.endpoint` is a discriminated union (`streamableHTTP` \| `sse` \| `stdio`, CEL-validated to exactly one). `url` and `headers` and `auth` live **under the transport**, not at `spec` top level. There is no `spec.transport` field. `MCPAuth` = `{secretStore, oauth2, spiffe}` — there is **no `clientCredentials` key**. `MCPOAuth2` = `{Issuer, Audience, Scopes, ClientID, SecretKeyRef}` — the token endpoint field is `issuer` not `tokenUrl`, the casing is `clientID` not `clientId`, and the secret field is `secretKeyRef` not `clientSecret.secretKeyRef`. The doc's own "Note on schema fidelity" correctly predicted this; the note is doing real work and should stay until the YAML is fixed. |
| 15d | 1.18 `MCPServer.auth` modes = static header injection, OAuth2 client credentials, SPIFFE JWT-SVID injection; daprd injects SVIDs into outbound MCP tool calls | B §2.1, §2.2 table, Appendix A | **PARTIALLY CORRECT** | Same file, `MCPAuth` / `SPIFFE` / `SPIFFEJWT` types | Substance right, taxonomy slightly off. `auth` has exactly **two** credential modes (`oauth2`, `spiffe`) plus `secretStore` (a resolver, not a mode). Static headers are `spec.endpoint.<transport>.headers`, a sibling of `auth`, not an auth mode. SPIFFE injection is confirmed and is **opt-in configuration**, not automatic: `SPIFFEJWT{Header, HeaderValuePrefix, Audience}` names the header to inject into. "daprd injects SPIFFE JWT-SVIDs into outbound MCP tool calls" is true **when so configured** — worth the qualifier in an Appendix that leans on it. |
| 16a | No `sts` component type exists in components-contrib | B §2.2, §4.1 | **CONFIRMED** | `dapr/components-contrib` full-tree listing, master | Component-type directories are exactly: `bindings`, `configuration`, `conversation`, `crypto`, `lock`, `middleware`, `nameresolution`, `pubsub`, `secretstores`, `state`. No `sts`. Repo-wide grep for `8693`/`token_exchange`/`tokenexchange` hits exactly one file, `common/authentication/azure/spiffe.go`, and that is workload-identity client assertion, not token exchange. |
| 16b | No delegated-authority mechanism or in-flight proposal in Dapr | B §2.2 | **CONFIRMED** | `dapr/proposals` @ `9ca8958`, all 26 proposal files | Grep for `on.behalf.of`, `delegated authorit`, `security token service`, `token exchange`, `8693` across every `.md`: only two hits, both incidental lines inside the MCPServer proposal describing an OAuth2 client-credentials failure mode. **No prior or in-flight delegation/STS proposal exists.** The gap the proposal claims is real. |
| 17a | `middleware.http.oauth2clientcredentials` — statically configured per pipeline, no subject token, app identity only | B §2.2 | **CONFIRMED** | [`components-contrib/middleware/http/oauth2clientcredentials/oauth2clientcredentials_middleware.go`](https://github.com/dapr/components-contrib/blob/master/middleware/http/oauth2clientcredentials/oauth2clientcredentials_middleware.go); https://docs.dapr.io/reference/components-reference/supported-middleware/middleware-oauth2clientcredentials/ | `GetHandler` returns `func(next http.Handler) http.Handler` — pipeline middleware. Config is `clientcredentials.Config{ClientID, ClientSecret, Scopes}` from static metadata. RFC 6749 §4.4 client credentials; no subject anywhere. |
| 17b | `middleware.http.bearer` — validation of inbound tokens, not acquisition | B §2.2 | **CONFIRMED** | https://docs.dapr.io/reference/components-reference/supported-middleware/middleware-bearer/ | "verifies a Bearer Token using OpenID Connect on a Web API". |
| 17c | `secretstores` static credentials; `crypto` is key ops on payloads, not token issuance | B §2.2 | **CONFIRMED** | components-contrib directory listing + https://docs.dapr.io/developing-applications/building-blocks/cryptography/cryptography-overview/ | Uncontroversial and correct. |
| 17d | Component Azure auth profiles perform a real exchange but are hardcoded per cloud and unreachable from app/workflow code | B §2.2 | **CONFIRMED** | [`components-contrib/common/authentication/azure/spiffe.go`](https://github.com/dapr/components-contrib/blob/master/common/authentication/azure/spiffe.go) | `SpiffeWorkloadIdentityConfig.GetTokenCredential()` builds an `azidentity.ClientAssertionCredential` with the SPIFFE JWT as assertion against `api://AzureADTokenExchange`. Real federated exchange, `azure`-package-specific, `TenantID`/`ClientID` from component metadata only. Row is accurate. |
| 18 | Entra OBO is not literal RFC 8693 — `grant_type=jwt-bearer` + `requested_token_use=on_behalf_of` | B §4.1 table | **CONFIRMED** | https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-on-behalf-of-flow | Microsoft's own parameter tables: `grant_type` value MUST be `urn:ietf:params:oauth:grant-type:jwt-bearer`; `requested_token_use` REQUIRED and MUST be `on_behalf_of`; the inbound token goes in `assertion`, not `subject_token`. Exactly as the doc states. Corroborated independently by agentgateway. |
| 19 | RFC 8693 mechanics: `actor_token`/`act` chain, impersonation-vs-delegation, token type URIs, impersonation by dropping the actor chain | B §4.1, §7.4 | **CONFIRMED** | https://www.rfc-editor.org/rfc/rfc8693.html | All four confirmed. `act` "chain of delegation can be expressed by nesting one `act` claim within another"; `actor_token_type` REQUIRED when `actor_token` present; impersonation = subject_token only, "indistinguishable from B". Minor precision: impersonation arises from **not supplying an actor component at all**, rather than from actively "dropping" an existing chain — cosmetic, the doc's §7.4 framing is defensible. |
| 20 | MCP spec security guidance forbids token passthrough | B §2.3, §7.3 | **CONFIRMED** (with a staleness flag) | https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization ; https://modelcontextprotocol.io/specification/2026-07-28/basic/security_best_practices ; https://modelcontextprotocol.io/specification/versioning | Prohibition survives into the current revision: *"MCP servers **MUST NOT** accept or transit any other tokens"* (authorization, Token Handling) and *"MCP servers **MUST NOT** accept any tokens that were not explicitly issued for the MCP server"* (security best practices, Token Passthrough → Mitigation). **However:** the crisp sentence closest to the doc's paraphrase — *"The MCP server MUST NOT pass through the token it received from the MCP client"* — is from the **2025-06-18** revision. The **current** revision is **2026-07-28** (2025-11-25 intervened), and in it that sentence has moved into the `authorization/security-considerations` subpage. Cite a revision. |
| 21 | agentgateway `backendAuth.oauthTokenExchange` covers 8693 + 7523 jwt-bearer + Entra OBO; Solo enterprise adds a built-in STS | B §2.4, §8 | **CONFIRMED** | https://agentgateway.dev/blog/2026-07-12-agentgateway-token-exchange-jwt-assertion-entra-obo/ ; https://docs.solo.io/agentgateway/2.3.x/security/token-exchange/ | Field name and all three mechanisms confirmed (`grantType: jwtBearer`; Entra via `additionalParams` with `requested_token_use: on_behalf_of`). Enterprise STS confirmed: "The controller runs the Secure Token Service (STS) which does RFC 8693 token exchange and owns the token vault." One correction of emphasis: the OSS side is **more** capable than "gateway-side config" implies — all three exchange types were open-sourced in July 2026. Enterprise adds the STS *server*, the token vault, elicitation-based credential forwarding, and delegation with `act`. Source tier: vendor project blog + vendor product docs — official for the product, but not code. |
| 22 | RFC 7523 `private_key_jwt`-style client assertion | B §4.1 | **CONFIRMED** | https://www.rfc-editor.org/rfc/rfc7523.html §2.2 | `client_assertion_type` = `urn:ietf:params:oauth:client-assertion-type:jwt-bearer`, `client_assertion` carries exactly one JWT. Nuance: **"private_key_jwt" is an OpenID Connect Core term and does not appear in RFC 7523.** The doc's "-style" hedge makes this fine as written. |
| 23 | Does `dapr/proposals` have a required format? | B (whole doc) | **CONFIRMED — and doc B does not conform** | [`dapr/proposals/README.md`](https://github.com/dapr/proposals/blob/main/README.md), [`templates/proposal.md`](https://github.com/dapr/proposals/blob/main/templates/proposal.md) | Yes, mandatory and specific. See "Corrections required" §C below. |

---

## Corrections required

### C1. Doc A §2 and summary table — the workflow versioning claim is wrong

Current text (§2):

> Dapr's story here is thinner. The mitigation is to avoid needing it: keep instances short-lived and narrowly scoped, so the population of in-flight instances turns over faster than the deploy cadence, and keep an external ledger — not workflow history — as the system of record for long-running business state. Under that discipline, a versioning problem degrades into a restartable unit of work rather than a lost process.

Replacement:

> Dapr addresses this with the same two mechanisms. Patch-based versioning (`IsPatched()` / `is_patched()`) wraps a change in a named conditional whose application is recorded in workflow history, so replays take a consistent path. Named workflow versioning registers a new versioned workflow type and routes new instances to the latest while in-flight instances stay pinned to the version they started on — `@wfr.versioned_workflow(is_latest=…)` in Python, `AddVersionedWorkflow(…, isLatest)` in Go, source-generated registration in .NET. Both shipped in Dapr 1.18 and are documented at [Workflow versioning](https://docs.dapr.io/developing-applications/building-blocks/workflow/workflow-versioning/). The design rationale, including an explicit comparison to Temporal's implementation of both, is in [`20251028-BRS-workflow-versioning.md`](https://github.com/dapr/proposals/blob/main/20251028-BRS-workflow-versioning.md).
>
> The remaining difference is in kind, not presence: Temporal's Worker Versioning pins instances to a worker *build* at the deployment layer, whereas Dapr's named versioning routes in the SDK's workflow registry. Dapr's proposal argues this is deliberate — it minimizes versioning state in the runtime and lets each SDK use its own idiomatic registration — but it does mean the unit of pinning is a workflow type, not a worker deployment.

Summary table row:

| current | replacement |
|---|---|
| `Versioning long-running instances \| Patching + worker versioning \| Thin; mitigate with short-lived instances` | `Versioning long-running instances \| Patching + worker versioning (pins to worker build) \| Patching + named workflow versions (pins to workflow type), 1.18` |

The "Choosing between them" section must change too. Currently:

> Prefer Temporal when workflows are long-running enough that in-flight instances will outlive several deploys,

That reason no longer distinguishes the two engines and should be deleted or narrowed to the worker-build-pinning distinction. The final paragraph's "The gaps above are real" survives, but one of the four gaps has closed.

### C2. Doc A §5 and summary table — SPIFFE per-agent identity

Current (§5):

> Dapr Agents' `DurableAgent` was the only one shipping a first-party, reusable **agent-loop class** — memory tiers, tool calling, and multi-agent orchestration as framework code — together with **SPIFFE-based per-agent cryptographic identity**.

Replacement:

> Dapr Agents' `DurableAgent` was the only one shipping a first-party, reusable **agent-loop class** — memory tiers, tool calling, and multi-agent orchestration as framework code. Separately, because every Dapr sidecar receives a Sentry-issued SVID bound to `spiffe://<trust-domain>/ns/<namespace>/<app-id>`, an agent deployed as its own Dapr app gets cryptographic workload identity for free. That is a property of the runtime the agent happens to sit on, not a feature of `DurableAgent` — the string `spiffe` does not occur anywhere in `dapr/dapr-agents`.

Summary table row `Per-agent cryptographic identity | No | Yes (SPIFFE)` should become `Per-app SPIFFE workload identity | No | Yes (via Dapr Sentry, not the agent framework)`.

### C3. Doc A §5 — Temporal's agent story

Current:

> The others, Temporal included, provide a durable task or step primitive and leave the agent loop as application code, even where their marketing points at agents.

Replacement:

> The others provide a durable task or step primitive and leave the agent loop as application code. Temporal is the partial exception: it ships no agent-loop class of its own, but `temporalio.contrib.openai_agents` (first-party, in the Python SDK repo, GA since March 2026) supplies a `Runner` implementation that drives the OpenAI Agents SDK's loop and turns every LLM and tool call into an activity automatically. Temporal wraps someone else's loop durably; Dapr Agents defines its own.

### C4. Doc A §4 — the state-key claim

Current:

> The `secretKeyRef.name` is appended to the state key so Dapr knows which key encrypted which item.

Replacement:

> The `secretKeyRef.name` is appended to the stored **value**, after a `||` separator, so Dapr knows which key encrypted which item. (Dapr's own documentation says "state key" here; the implementation in `pkg/encryption/state.go` appends to the value.)

### C5. Doc A §3 — payload ceiling behaviour

Add after the 4 MiB sentence:

> The limit is enforced as a stall rather than a hard failure: at 95% of the configured size the workflow is marked `PAYLOAD_SIZE_EXCEEDED` and parks, and it resumes if the cluster is rolled to a larger `--max-body-size`.

### C6. Doc B §4.3 — the `MCPServer` YAML must be rewritten

Current "Before" block is structurally wrong at every level. Corrected against `pkg/apis/mcpserver/v1alpha1/types.go` at tag `v1.18.3`:

```yaml
apiVersion: dapr.io/v1alpha1
kind: MCPServer
metadata:
  name: expenses-tools
spec:
  endpoint:
    streamableHTTP:
      url: https://mcp.acme.example/mcp
      auth:
        secretStore: kubernetes
        oauth2:
          issuer: https://as.acme.example/oauth2/token
          clientID: agent-service
          secretKeyRef: { name: agent-creds, key: secret }
          audience: https://mcp.acme.example/mcp
          scopes: ["expenses.read"]
```

The "After" block must nest identically — `spec.endpoint.streamableHTTP.auth.onBehalfOf`, not `spec.auth.onBehalfOf`. This also strengthens §4.3's own argument: the proposal is adding a third variant to an existing two-variant `MCPAuth` union, which is a smaller and more reviewable change than a new top-level `spec.auth` block would be. Say so.

### C7. Doc B §2.1 — MCPServer auth mode taxonomy

Current:

> Its auth modes are static header injection, OAuth2 client credentials (secret fetched at call time from a Dapr secret store), and SPIFFE JWT-SVID injection.

Replacement:

> `MCPAuth` offers two credential modes — OAuth2 client credentials (`auth.oauth2`, client secret resolved at call time via `auth.secretStore`) and SPIFFE JWT-SVID injection (`auth.spiffe.jwt`, which names the header, optional value prefix, and required audience). Static headers are configured separately, as `spec.endpoint.<transport>.headers`, alongside `auth` rather than inside it.

### C8. Doc B §2.2 — the `MCPServer.auth` table row

Current: `` `MCPServer.auth` (1.18) | Client credentials and SVID injection — both app identity ``

Replacement: `` `MCPServer.auth` (1.18) | `oauth2` client credentials and `spiffe.jwt` SVID injection — both app identity; `MCPAuth` is a two-variant union this proposal extends to three ``

### C9. Doc B §2.3, §7.3 — cite an MCP spec revision

Current §2.3:

> The MCP specification's security guidance independently forbids raw token passthrough

Replacement:

> The MCP specification (revision 2026-07-28) independently forbids raw token passthrough: *"MCP servers **MUST NOT** accept or transit any other tokens"* ([Authorization, Token Handling](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)), reinforced in [Security Best Practices, Token Passthrough](https://modelcontextprotocol.io/specification/2026-07-28/basic/security_best_practices).

### C10. Doc B — conform to the `dapr/proposals` template

The repo has a mandatory process (`README.md`) and template (`templates/proposal.md`) the document does not follow. Required changes:

1. **Filename.** `YYYYMMDD-FLAGS-description.md`. Flags: **B** (building block), **C** (components), **R** (runtime), **S** (SDKs). This proposal is all four → `20260901-BCRS-delegated-identity-token-exchange.md`.
2. **Header.** The template opens with `# Feature name` then a `# Links` section (relevant proposals, existing issues, milestones). Doc B's `Status / Target repo / Affects / Author / Date` block is not the template's shape; accepted proposals in the repo use `- Author:` / `- Status:` / `- Introduced MM/DD/YYYY`.
3. **Missing required section: `# Lifecycle Expectations`** — Alpha / Beta / Stable expectations covering anticipated performance and known limitations, compatibility guarantees, deprecation and co-existence, and required feature flags. Doc B has a Phase 1/2/3 implementation plan, which is *not* the same axis and does not substitute.
4. **Missing required section: `# Acceptance criteria`** as the template's per-stage checkbox lists. Because this is both a new component type and a new API, the template requires, at Alpha: interfaces agreed with `dapr/dapr`, the new building-block package defined in `components-contrib`, conformance tests, at least one implementation, ≥1 core SDK, docs in `dapr/docs`, telemetry metrics, a `dapr/quickstarts` issue, **and both HTTP and gRPC protocols implemented**. Doc B §4.1 specifies only `POST /v1.0-alpha1/sts/<component>/exchange` — **no gRPC surface is specified anywhere**, which will block Alpha as written. At Beta the template requires a minimum of three (proposed) building-block implementations; §10 Phase 3 makes `sts.aws` conditional, so plan for at least `rfc8693`, `azure.entra`, and `gcp`.
5. **Process.** Fork → copy template → PR to `dapr/proposals` → majority vote of the relevant repo's maintainers → on merge, open a `dapr/dapr` issue from `templates/lifecycle.md`. The doc's §10 "Sequencing note" (split phases 1 and 2) is good instinct and consistent with how the repo's larger proposals were handled.
6. **Keywords.** README mandates RFC 2119 interpretation of MUST/SHOULD/MAY. Doc B already uses these correctly; add the boilerplate note.

### C11. Doc A §4 — state-store encryption does NOT cover workflow history

*Added on re-open. This reverses my original finding #8; the corrected verdict is REFUTED.*

**Why the original verdict was wrong.** I confirmed that workflow history lands in the actor state store and treated "encryption is applied at the state-store layer" as following from it. That second step was inference, and it is false. Dapr's automatic encryption is not a property of the store object; it is a lookup keyed by store *name* that only fires where someone explicitly calls it, and the actor path never calls it.

**The decisive code.** [`pkg/runtime/processor/state/state.go`](https://github.com/dapr/dapr/blob/v1.18.3/pkg/runtime/processor/state/state.go), identical at tag `v1.18.3` and on master:

```go
 84:  store, err := s.registry.Create(comp.Spec.Type, comp.Spec.Version, fName)
...
105:      ok := encryption.AddEncryptedStateStore(comp.Name, encKeys)   // side table, keyed by NAME
...
140:          if err = s.compStore.AddStateStoreActor(comp.Name, store) // <- same unwrapped `store`
158:  s.compStore.AddStateStore(comp.Name, store)                       // <- same unwrapped `store`
```

Line 105 is the whole of the registration path's involvement with encryption, and `AddEncryptedStateStore` does nothing but insert into a package-global `map[string]ComponentEncryptionKeys` in [`pkg/encryption/state.go:22,29`](https://github.com/dapr/dapr/blob/master/pkg/encryption/state.go). **The `store` value produced at line 84 is passed to lines 140 and 158 unmodified.** There is no decorator, no wrapper, no interface interposition. `ComponentStore.AddStateStoreActor` ([`pkg/runtime/compstore/statestore.go:30-48`](https://github.com/dapr/dapr/blob/master/pkg/runtime/compstore/statestore.go)) likewise just files the raw `state.Store` into a map. This was the specific hypothesis to rule out, and it is ruled out.

**Consequence: the actor path never encrypts.** [`pkg/actors/state/state.go`](https://github.com/dapr/dapr/blob/master/pkg/actors/state/state.go) does not import `pkg/encryption` at all (confirmed at `v1.18.3` too) and writes through `store.Multi(ctx, stateReq)` at line 248, with `store.Get` at 120 and `store.BulkGet` at 169. A full census of every non-test caller of `TryEncryptValue` / `TryDecryptValue` / `EncryptedStateStore` across `dapr/dapr` returns nine sites, all in the state building block's public API: `pkg/api/grpc/grpc.go:658,665,724,725,792,793,1035,1040`, `pkg/api/http/http.go:585,592,684,685,1039,1041,1600,1605`, `pkg/api/universal/state_query.go:62`. Zero occurrences of `encrypt` (case-insensitive, non-test) anywhere under `pkg/actors/` or `pkg/runtime/wfengine/`.

The near-miss is worth noting: `executeStateStoreTransaction` already resolves `storeName` into scope (it passes it to the resiliency policy) — the exact key `TryEncryptValue` needs. The mechanism is sitting right there, simply not wired up.

**`actorStateStore: true` is not special-cased for encryption.** The only thing the `actorStoreSpecified` branch does differently is register the store as the actor store and notify the actor runtime. It receives the identical unwrapped object.

**Current text (§4):**

> Since Dapr Workflow persists through the actor state store, enabling encryption on that store does encrypt workflow history at rest.

**Replacement:**

> Dapr Workflow persists through the actor state store, but enabling automatic encryption on that store does **not** encrypt workflow history. Dapr's automatic encryption is applied at the state building block's public API — the `/v1.0/state` HTTP and gRPC handlers call `TryEncryptValue` / `TryDecryptValue` before and after the component. Workflow history is written on the actor path (`pkg/actors/state/state.go`), which calls the component's `Multi`/`Get` directly and never consults the encryption package. The component object itself is not wrapped: `pkg/runtime/processor/state/state.go` merely records the keys in a name-keyed side table and hands the same unwrapped store to both consumers. So application state your activities write through the state API **is** encrypted, while the workflow history recording those activities' inputs and outputs is written in the clear.
>
> This makes gap 4 below considerably worse than "granularity" and "pluggability" suggest: for workflow history specifically, Dapr's application-layer encryption story is not coarse, it is absent. The only encryption available for workflow history today is whatever the backing database provides at rest — Redis/Postgres disk encryption, CosmosDB or DynamoDB service-side keys — which is real protection against stolen media but gives the keys to the infrastructure operator, the precise party a payload codec exists to exclude. No `components-contrib` state store implements encryption of its own either.

**Knock-on edits:**

- Summary table row `History encryption | Client-side, pluggable payload codec | Sidecar AES-GCM on the state store` → `History encryption | Client-side, pluggable payload codec | None for history; sidecar AES-GCM covers only the state API`.
- §4's framing sentence **"Dapr is not starting from zero"** now overstates the position for the topic of that section. It is true of application state and false of workflow history. Recast as "Dapr has the pieces, but not on this path."
- §4's **"The gaps are about control, not about ciphers"** is no longer accurate as the section's thesis. For workflow history the gap is coverage, not control.
- §4 gap 3 ("No decode path for tooling") says operators "either hold the key or see ciphertext." For workflow history there is no ciphertext to see — a console reading history sees plaintext. That strengthens the doc's regulated-multi-tenant argument and should be restated accordingly.
- §4's closing to-do list ("a per-payload codec hook in the workflow runtime running before the payload reaches the state store…") is unchanged and now reads as strictly necessary rather than as an enhancement.

---

## Claims that need softening

1. **Doc A, "This is the largest functional gap, and it is not subtle."** With versioning corrected (C1), execution control genuinely is the largest remaining gap — but the sentence currently sits in a document that also overstates the versioning gap, so the comparative claim was inflated by contrast. It stands after C1; it did not before.

2. **Doc A §1, "The asymmetry is the tell that this is a design boundary rather than an oversight."** This is an argument, presented as a finding. The evidence supports something narrower and stronger: the *protobuf* has no timeout field on `ScheduleTaskAction`, so adding one is a wire-format change, not an SDK change. Lead with that fact and let the asymmetry be the supporting rhetoric rather than the proof.

3. **Doc A §4, "Dapr should be assumed to have the same exposure" (stack traces).** Correctly hedged already. But the summary table hardens it to `Stack-trace payload leakage | Acknowledged, not covered by default | Same exposure, undocumented`, which reads as verified. Two different confidence levels for one claim. Make the table row `Presumed same exposure; not documented either way`.

4. **Doc A §4, gap 3, "There is no third option."** Structurally true of state-store encryption, but the phrasing forecloses adjacent designs (an operator-run decode proxy holding the key, envelope encryption at the application layer above the activity boundary). Soften to "Dapr offers no third option" — the limitation is Dapr's, not the problem space's.

5. **Doc B §2.4, "OSS agentgateway's `backendAuth.oauthTokenExchange` covers … as gateway-side config; Solo's enterprise build adds a full built-in STS."** Accurate but undersells the competition, which weakens the proposal by making the alternative look thinner than it is. Solo Enterprise ships not merely an STS but a token vault, delegation with a real `act` chain, impersonation, external-IdP delegation, and elicitation-based OAuth credential capture. §8's "Alternatives considered" should engage with delegation-with-`act` specifically, since that is the closest existing thing to this proposal's core value proposition. The durable-workflow argument in §2.4 survives intact — a gateway still cannot span a three-day timer — but it should be made against the strongest version of the alternative.

6. **Doc B §2.1, "daprd already attaches credentials to outbound tool calls"** and Appendix A's "As of 1.18, daprd injects SPIFFE JWT-SVIDs into outbound MCP tool calls." True only when `auth.spiffe.jwt` is configured on the `MCPServer`. Appendix A is the doc's rebuttal to the main objection, so an unqualified claim there is the worst place to be imprecise. Add "when configured to".

7. **Doc B §7.4, "RFC 8693 permits impersonation, where `sub` becomes the user and the actor chain is dropped."** RFC 8693's impersonation case is the *absence* of an actor component, not the removal of one. Immaterial to the design decision, but a reviewer who knows the RFC will notice.

8. **Doc B §4.1, "`private_key_jwt`-style client assertion (RFC 7523)."** The "-style" hedge is correct and load-bearing — `private_key_jwt` is OpenID Connect Core vocabulary, absent from RFC 7523. Do not let an editing pass tighten this into "private_key_jwt (RFC 7523)".

---

## What I could not verify, and why

1. **"No timeout parameter at any level" across the .NET and Java SDKs.** I verified Python (v1.18.3 tag) and Go (durabletask-go main) directly, and the protobuf — which is the real proof, since no SDK can send a field the wire format lacks. I did not clone `dapr/dotnet-sdk` or `dapr/java-sdk`. The proto argument makes this a formality, but the doc's phrase "at any level" is broader than what I checked directly.

2. **Whether `20251028-BRS-workflow-versioning.md` is formally *accepted*.** Its header says `Status: Proposed`. It is merged into `dapr/proposals` main, and per the repo README merging follows acceptance — but the header was not updated, so the two signals disagree. This does not affect the C1 correction, which rests on shipped code and shipped docs, not on the proposal's status.

3. **Whether Dapr's named workflow versioning is GA, beta, or preview in 1.18.** The versioning docs page does not carry a preview banner and the feature is absent from the preview-features list I could retrieve, but https://docs.dapr.io/operations/configuration/preview-features/ documents only the *mechanism* for enabling preview features and enumerates none, so I could not confirm the stability tier positively. Treat "shipped in 1.18" as established and "GA" as unverified.

4. **The exact release in which `dapr/durabletask-go` gained `IsPatched`.** I read it on `main` (v0.14.x lineage) and confirmed the SDK-level surface (`is_patched`, `register_versioned_workflow`) at python-sdk tag `v1.18.3`, and runtime `WorkflowVersion` handling at dapr tag `v1.18.3` (which pins durabletask-go `v0.12.4`, versus `v0.14.1` on dapr master). So versioning is in 1.18, but some of the machinery I read on `main` is ahead of the 1.18.3 pin and may belong to 1.19. If the correction text needs to be exact about which knob exists in which patch release, re-check against the `v0.12.4` tag of durabletask-go specifically.

5. **`dapr/dapr` version metadata.** `pkg/buildinfo` reports `version = "edge"` in a clone; version attribution throughout this report is by `git ls-tree` / `git show` against release tags, which is reliable for file and symbol presence but tells you nothing about whether a present symbol was wired up and enabled in that release.

6. **Temporal's four-timeout claim beyond the encyclopedia page.** Confirmed from docs.temporal.io only. I did not cross-check `temporalio/sdk-go`'s `ActivityOptions` struct or the `temporalio/api` protobufs. Confidence is high (this is Temporal's own canonical reference page) but it is docs, not code — asymmetric with the code-level rigor applied to the Dapr side, and worth noting since the document's whole rhetorical structure is a Dapr-vs-Temporal comparison.

7. **The claim in doc A §5 that this was "a survey of six durable-execution and orchestration platforms plus Temporal."** The other five platforms are never named, so there is nothing falsifiable to check. Either name them or drop the appeal to a survey — as written it borrows authority from evidence the reader cannot inspect, and it is the sentence that carries the (now partly refuted) `DurableAgent` uniqueness claim.

8. **That no state store encrypts workflow history by some route I did not think to check.** The negative half of C11 — "there is no supported way to encrypt workflow history at rest in Dapr today" — is the weaker half of that finding. The positive half (encryption is invoked only at the state API, the store is never wrapped, the actor path never calls it) is airtight and traced. The negative half rests on: no non-test caller of the encryption helpers outside `pkg/api/`; no `encrypt` string under `pkg/actors/` or `pkg/runtime/wfengine/`; and no `encrypt` in any non-test `.go` file under `components-contrib/state/`. That is a thorough absence search, but it is still an absence search. It would not catch encryption applied by a state store's own upstream SDK (e.g. a client library configured with customer-managed keys through ordinary component metadata that never uses the word "encrypt" in contrib code). Infrastructure-level at-rest encryption in the backing database is unaffected by any of this and remains available.

9. **agentgateway OSS-vs-Enterprise boundary in detail.** Established from Solo's product docs (`docs.solo.io/agentgateway/2.3.x`) and the agentgateway project blog. Both are official vendor sources, neither is source code, and the OSS/Enterprise line in a commercial product moves. The specific claim "Solo's enterprise build adds a full built-in STS" is confirmed as of the 2.3.x docs; treat the boundary as point-in-time.
