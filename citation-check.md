# Citation check — agentic-authorization batch

Every URL below was actually opened. Checked 2026-09-01. Documents referred to as D1 (`rfc-8693-and-9396-in-practice.md`), D2 (`typed-grants-in-a-durable-engine.md`), D3 (`multi-tenant-agentic-workflows.md`), D4 (`typed-intent-and-containment.md`).

Headline: the citation quality is high. Every arXiv ID resolves to the paper claimed, the CB4A draft verifies word-for-word including the normative quotations, the Dapr OPA quotations are verbatim, and the 25+ XAA launch-partner list — flagged as the riskiest item — is fully confirmed by Okta's own press release. Six items need fixing, only three of them substantive.

## Table

| Citation | Doc | Resolves? | Says what is claimed? | Verdict | Note |
| --- | --- | --- | --- | --- | --- |
| arXiv 2605.05440 — Tallam, *Authorization Propagation in Multi-Agent AI Systems* | D1 | Yes | Yes | **OK** | Title, sole author, May 2026 (submitted 6 May) all match. §7.1 lists the four traceability items verbatim; §7.2 matches the "independent reviewer" paragraph. See note on the "four chains" label below. Author affiliation is Kamiwaza AI. |
| arXiv 2603.00991 — *Tracking Capabilities for Safer Agents* | D1 | Yes | Partly | **OK, minor** | Odersky, Zhao, Xu, Bračevac, Pham. v1 2026-03-01, v2 2026-05-07 (doc cites v2 — correct). It is Scala 3 capture checking / static capability types, not taint tracking; listing it under a "Taint tracking" row as "adjacent 2026 work" is defensible but slightly misleading. |
| arXiv 2606.04990 — execution-provenance survey | D1 | Yes | Yes | **OK** | Actual title *From Agent Traces to Trust: A Survey of Evidence Tracing and Execution Provenance in LLM Agents*, Wang et al., 2026-06-03. The doc's description is accurate. |
| arXiv 2503.18813 — CaMeL, *Defeating Prompt Injections by Design* | D4 | Yes | Yes | **OK** | Debenedetti, Shumailov, Carlini, Tramèr et al. — Google DeepMind + ETH Zurich as claimed; v1 2025-03-24. |
| `draft-hartman-credential-broker-4-agents-00` (CB4A) | D4 | Yes | Yes | **OK — expiry note** | Kenneth G. Hartman, **SANS Institute**, dated **29 March 2026**. Threat model is exactly TM-1…TM-11. **Expires 30 September 2026.** |
| CB4A "highest-value target in the architecture" | D4 | — | Yes | **OK** | Verbatim: "The broker (CDP) is the highest-value target in the architecture." TM-1 severity is `CRITICAL`. Hardening line verbatim: "It MUST be hardened with no shell access, restricted network, and credential zeroing after minting (TM-1)." |
| CB4A "MUST NOT default to fail-open under any failure condition" | D4 | — | Yes | **OK** | Verbatim (TM-9). |
| CB4A TM-11 Broker Bypass / network-level DNS + egress | D4 | — | Yes | **OK** | Named "Broker Bypass", severity HIGH. Mitigations include "Network-level enforcement…" and "DNS-level controls resolving brokered endpoints to CB4A proxy." Doc's "rather than agent cooperation" tracks §7's "MUST be prevented through network-level enforcement, not agent cooperation (TM-11)." |
| CB4A Models A/B/C, Model B recommended | D4 | — | Yes | **OK** | Model B "is the RECOMMENDED primary model for CB4A". |
| CB4A March 2026 supply-chain motivation | D4 | — | Yes | **OK — see RECOMMEND** | §1.3 verbatim: "In March 2026, the TeamPCP supply chain campaign compromised LiteLLM… 300+ GB of compressed credentials affecting approximately 500,000 corporate identities." The "when AI infrastructure concentrates long-lived credentials…" quotation is verbatim. |
| Posta, *Credential Injection Patterns for AI Agents* (agentgateway) | D4 | Yes | Yes | **OK** | Christian Posta; two-part series. Model-A-primary position verbatim: "The draft's recommended primary is Model B, with Model A as the selective fallback. I'm going to argue that for most enterprises today, that recommendation is backward." |
| `draft-chen-oauth-rar-agent-extensions-00` | D1 | Yes (HTTP 200) | Yes | **FIX — expired** | Meiling Chen + Li Su, China Mobile, 2026-02-04, individual submission, "not endorsed by the IETF" — all correct. Adds `policy_context` and `lifecycle_binding` exactly as described. **Expired 8 August 2026.** |
| MCP issue #1670 | D1 | Yes | **No** | **FIX** | Title matches ("Support Rich Authorization Requests for OAuth - RFC 9396"), opened by jaiminbhatt7 2025-10-17 — but it is **CLOSED**, not "an open request". |
| openclaw issue #39160 | D1 | Yes | **No** | **FIX** | Exists: "RFC: CaMeL Prompt Injection Defense for OpenClaw", nashborges, 2026-03-07. **Closed as not planned**, not "an active RFC". |
| Dapr MCP OPA quote 1 | D1 | Yes | Yes | **OK** | Page reads: "OPA per-tool policies: Argument- and tool-aware authorization that inspects the MCP JSON-RPC body." Verbatim except sentence-initial capitalization. |
| Dapr MCP OPA quote 2 | D1 | Yes | Yes | **OK** | Page reads: "Use the `MCPServer` resource when you specifically need: Argument-level RBAC, audit, or redaction hooks on a per-tool basis (`beforeCallTool` / `afterCallTool` / `beforeListTools` / `afterListTools`)." Verbatim. |
| Okta Agent SSO GA 2026-08-24 | D1 | Yes | Yes | **OK** | Okta press release confirms GA on 2026-08-24, agents registered as first-class identities in Universal Directory, short-lived tokens replacing static API keys, included in core SSO plans at no extra cost. All four sub-claims correct. |
| XAA = MCP Enterprise-Managed Authorization extension, 25+ partners incl. Anthropic, Cloudflare, Datadog, Figma, Zoom | D1 | Yes | Yes | **OK — verified individually** | Okta release (2026-06-23) says "25+ early adopters" and names all five: Anthropic ✓ Cloudflare ✓ Datadog ✓ Figma ✓ Zoom ✓. Full list also includes Asana, Atlassian, Canva, Cursor, Docker, Glean, Keycloak, Linear, Slack, Supabase, VS Code, WorkOS and others. Corroborated by blog.modelcontextprotocol.io/posts/enterprise-managed-auth. **Do not cut the list.** |
| Auth0 XAA early access end of July 2026 | D1 | Yes | Yes | **OK** | Auth0's own XAA post states early access at end of July 2026; XAA for Resource Applications is now in Open Early Access. |
| Auth0 native RAR, Dan Moore 2026-03-30 | D1 | Yes | Partly | **FIX (one instance)** | ciamweekly.substack.com post is by Dan Moore, dated exactly 2026-03-30. It says "Auth0 **and other major identity providers** have added native support for RAR." See MUST FIX #3. |
| OpenID4VCI 1.0 Final, 2025-09-16 | D1 | Yes | Yes | **OK** | OpenID Foundation announcement confirms Final approved 2025-09-16 (102 approve / 1 object / 12 abstain). `openid_credential` authorization-details type confirmed in the spec. |
| Keycloak 26.2 token exchange (May 2025) | D1 | Yes | Partly | **Soften** | keycloak.org/2025/05/standard-token-exchange-kc-26-2 confirms "officially supported", RFC 8693 compliant. But 26.2.0 itself shipped April 2025, and support is scoped to internal-token-to-internal-token. |
| Keycloak 26.5 (Jan 2026), RFC 7523 + identity chaining | D1 | Yes | Partly | **Soften** | keycloak.org/2026/01/jwt-authorization-grant confirms both, Jan 2026. But JWT Authorization Grant was **preview** in 26.5 and only promoted to supported in 26.6 (April 2026). |
| ZITADEL RFC 8693 | D1 | Yes | Yes | **OK** | ZITADEL docs: implements RFC 8693, actor parameters optional, impersonation and delegation; available from v2.49. |
| Authlete 2.3 token exchange | D1 | Yes | Yes | **OK** | Authlete docs list RFC 8693 support from 2.3 onward; 2.3 announced January 2023. |
| Microsoft Entra ID does not implement RFC 8693 | D1, D3 | — | Yes | **OK** | Confirmed across multiple independent sources: Entra uses RFC 7523 jwt-bearer with `requested_token_use=on_behalf_of` and does not accept the 8693 grant-type URN. |
| RFC 8693 (Standards Track, January 2020) | D1 | Yes | Yes | **OK** | Title, category, date, grant-type URN, `subject_token`/`actor_token`, `act`/`may_act`, impersonation-vs-delegation distinction all confirmed. |
| RFC 9396 (Standards Track, May 2023) | D1, D4 | Yes | Yes | **OK** | Confirmed, including the five common fields (`locations`, `actions`, `datatypes`, `identifier`, `privileges`), the Cartesian-product rule (§2.2), and §6.1's explicit refusal to define a comparison algorithm. |
| RFC 9449 DPoP (Standards Track, September 2023) | D4 | Yes | Yes | **OK** | Confirmed; `cnf`/`jkt` mechanism as described. |
| RFC 9126 PAR | D1 | Yes | Yes | **OK** | Standards Track, September 2021. Doc cites number only, no date — nothing to falsify. |
| RFC 7523 JWT bearer | D1, D3 | — | Yes | **OK** | Used correctly throughout. |
| Carman, *AI Agent Authorization: Why Intent is not an Authorization Problem* (Callibrity) | D4 | Yes | Yes | **OK** | Author James Carman confirmed. "The line runs between typed intent and open intent, not between authorization and judgment" is verbatim. Entra Agent ID GA April 2026 ✓ and Auth0 for AI Agents November 2025 ✓ both confirmed in the article. No publication date shown on the page. |
| WSO2 *Cells as the Containment Unit for Agentic Systems* | D1, D4 | Yes | Yes | **OK** | Abeysinghe, Dissanayaka, Ganepola, Kanagalingam; Summer 2026. Eight-layer cell ✓, four gateway edges ✓ ("turns one undifferentiated perimeter into four distinct enforcement points"), three identity types chained via RFC 8693 `act` ✓, and verbatim: "the agent runtime never holds a raw downstream credential. The gateway is the credential custodian." |
| Dapr 1.16 Sentry JWT + OIDC discovery (2025-09) | D1, D2, D3 | Yes | Yes | **OK** | Dapr v1.16 blog dated 2025-09-16 confirms Sentry JWT issuance, `/.well-known/openid-configuration`, `/jwks.json`, and Entra federation via a Federated Identity Credential bound to the SPIFFE ID. |
| Dapr 1.18 per-audience JWT-SVIDs, `MCPServer` resource | D1, D3 | Yes | Yes | **OK** | Dapr v1.18 blog (2026-06-10) and docs.dapr.io/developing-ai/mcp/mcp-server-resource confirm both. |
| OpenAI runs SpiceDB for ChatGPT Enterprise connectors, "tens of billions of fine-grained permissions" | D1 | Yes | **No (figure wrong)** | **FIX** | A public AuthZed customer story exists at authzed.com/customers/openai. It states "37 Billion+ Documents with fine-grained access controls" and ~5 million business users — it does **not** say "tens of billions of fine-grained permissions." |
| MCP specification revision | — | n/a | n/a | **N/A** | No document cites a dated MCP specification revision at all. Nothing to correct; if a revision is added later, the current one is 2026-07-28. |
| Dapr cryptography building block issue | — | n/a | n/a | **N/A** | Flagged in the extraction notes but does not appear in any of the four documents. Nothing to check. |
| Google Cloud multi-tenant agentic AI reference architecture | D1 | — | Unverified | **Low risk** | Mentioned in one clause with no URL and no specific claim attached. Fine as written, but consider adding a link or dropping the sentence. |

## MUST FIX BEFORE PUBLISHING

1. **D1: MCP issue #1670 is closed, not open.** The text reads "is an open request for RAR support in the Model Context Protocol." It was opened 2025-10-17 by jaiminbhatt7 and is **closed**. Rewrite as "was raised as a request for RAR support… and closed" — and note it strengthens the document's own argument, since RAR was requested in MCP and not adopted.

2. **D1: openclaw #39160 is closed as not planned, not "an active RFC."** The text reads "an active RFC to adopt CaMeL in the OpenClaw agent runtime." It is "RFC: CaMeL Prompt Injection Defense for OpenClaw" (nashborges, 2026-03-07), **closed as not planned**. "Active" is the single most falsifiable word in that table row and a reader will click it.

3. **D1: "Auth0 … is also the one commercial authorization server with native RAR support" is false.** Authlete, Curity and SecureAuth all publish RAR documentation, and Keycloak supports it too. The Dan Moore article does not support the exclusivity claim either — it says "Auth0 and other major identity providers have added native support for RAR." The earlier phrasing on line 57 ("the one commercial authorization server *named* as having added native RAR support") is defensible if scoped to that article; the version in the Okta/Auth0 paragraph is not. Cut "the one" or scope it explicitly to Moore's article.

4. **D1: the OpenAI/SpiceDB figure is wrong, but the claim is salvageable.** Do not cut it — a public AuthZed customer story exists. Restate to what the source says: SpiceDB backs fine-grained access control over **37 billion+ documents** for roughly **5 million business users** across ChatGPT's connectors, citing `https://authzed.com/customers/openai`. Drop "is reported to" once cited, and drop "tens of billions of fine-grained permissions" — that phrasing appears in secondary coverage, not in AuthZed's own page.

5. **D1: say that `draft-chen-oauth-rar-agent-extensions-00` expired 2026-08-08.** The URL resolves, so the link is safe, but publishing on 2026-09 while describing a lapsed individual draft in the present tense invites the correction. One clause fixes it.

6. **D4: note that the CB4A draft expires 2026-09-30.** Everything cited from it verifies, but the `-00` will lapse within weeks of publication. Add the date, or link the version-independent page `https://datatracker.ietf.org/doc/draft-hartman-credential-broker-4-agents/` so the citation survives a `-01`.

## RECOMMEND CUTTING

Nothing needs cutting. Two things recommended for cutting in the extraction notes turned out to be well-sourced and should be **restored or strengthened** instead:

- **The March 2026 AI-gateway supply-chain compromise should be named.** It is documented in the CB4A draft itself (§1.3, with the 300+ GB / ~500,000 corporate identities figures), in LiteLLM's own security advisory (`docs.litellm.ai/blog/security-update-march-2026`), and in independent reporting from Datadog Security Labs, Trend Micro, Resecurity, CloudSEK and Cycode. De-identifying it costs the passage its force for no risk reduction: the incident is not merely public, it is the draft's stated motivating example. Restore "LiteLLM" and "TeamPCP" with a citation to the draft plus one vendor writeup.
- **The OpenAI/SpiceDB datapoint should stay**, corrected per MUST FIX #4.

Two smaller judgment items, neither a cut:

- **D1, Keycloak row: two version caveats are missing.** 26.2's token exchange is scoped to internal-token-to-internal-token (brokering and impersonation were still "planned"), and 26.5's JWT Authorization Grant shipped as **preview**, reaching supported status only in 26.6 (April 2026). Also, 26.2.0 itself released in April 2025; May 2025 is the date of the "officially supported" announcement. A survey document that pins versions this precisely will be read precisely.
- **D1, Tallam row: "four chains" is the document's label, not the paper's.** §7.1 lists four traceability requirements, but only three are called chains — the first is "the initiating principal and their authorization state at workflow initiation." The substance is accurate and the doc already flags the framing as a checklist rather than a standard. Consider "four things a traceable system must reconstruct." Worth adding that the author's affiliation is Kamiwaza AI, since the paper's evidence base is "a production enterprise AI platform."

## SETTLED — the open Dapr question (D3)

D3 currently hedges: "What this research could **not** establish is a documented, first-class *application-facing* API for retrieving that JWT from the sidecar… Check the current docs and source before stating this either way."

**This can now be stated.** On `dapr/dapr` `main` as of 2026-09-01:

- `pkg/security/security.go:67` declares `FetchJWT(ctx context.Context, audience string) (string, error)` on the internal `Handler` interface; the implementation is at `pkg/security/security.go:504`, delegating to `jwtSource.FetchJWTSVID(ctx, jwtsvid.Params{Audience: audience})`.
- Its only production consumer is `pkg/runtime/mcp/auth/auth.go:255`, inside an HTTP round-tripper that **attaches** the token to outbound MCP calls. Everything else that references it is a fake or a test.
- It is unexported Go API under `pkg/`. There is no app-facing surface: a code search across `dapr/proto` returns exactly one JWT-bearing proto, `dapr/proto/sentry/v1/sentry.proto` — the sidecar↔Sentry certificate-signing exchange, not an app↔sidecar API — and `dapr/go-sdk` has **zero** matches for JWT.

So the answer is the one the document hoped for: as of v1.18 the sidecar can obtain and attach a Sentry-issued JWT-SVID, and the application has no supported way to retrieve it. Replace the hedge with the finding and the file references above. This is the strongest single piece of evidence in the batch for the document's own thesis, and leaving it as an open question gives it away to the first reader who greps.

## COULD NOT CHECK AND WHY

- **The 20-authorization-server discovery-metadata survey (2026-08-03).** Not externally checkable — it is the author's own primary research, and there is nothing published to compare against. It is also the empirical spine of D1 and the sole support for the "either doing open banking, or doing the easy half" opening. Item 2 of the extraction notes stands unresolved; publishing the script would settle it. I did not attempt to re-run the sweep, as that was outside this task.
- **Provenance of the healthcare payer-operations use case, and of `acme-health` / `operator:jdoe` / `C-4821` / `spiffe://…/ns/agents/triage-agent`.** Not verifiable from public sources by construction. Nothing about them appears in any indexed source I searched, which is weak evidence they are invented, but only the author can confirm.
- **Exact publication date of the Carman/Callibrity article.** The page carries no visible date; the article itself is confirmed and its content matches.
- **Whether the Tallam paper names "standardized agent delegation semantics, formal verification of authorization chains, and consistent tenant isolation across tool boundaries" as the specific gaps.** I read pages 1–12 of the PDF and verified the four-chain and auditability passages directly; the gap list appears later in the paper. §6.4's "No single framework satisfies all seven structural requirements" supports the substance of the doc's sentence. Low risk, unverified verbatim.
- Nothing in this batch was blocked, paywalled, or timed out. Every URL cited in the four documents returned HTTP 200 when fetched directly.
