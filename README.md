# Durable execution notes

Working notes on durable-execution engines and the authorization problems they inherit: how these systems actually behave, where their control surfaces differ, and which of those differences change a design decision.

## Notes

- [**Dapr Workflow vs. Temporal: where the gaps actually are**](dapr-workflow-vs-temporal.md) — both are log-based, event-sourced engines that recover by deterministic replay, so the differences are not in the core model. They are in execution control (Dapr has no activity timeouts and no heartbeat), versioning, payload ceilings, and history hygiene. Includes a summary table and a choosing-between-them section.

## Agent authorization

- [**What actually implements RFC 8693 and RFC 9396**](rfc-8693-and-9396-in-practice.md) — an implementation survey finding that the two halves of agent authorization are in wildly different states: OAuth token exchange is a shipping commodity across Keycloak, ZITADEL, Authlete, Auth0 and every serious gateway, while Rich Authorization Requests is a ratified standard that zero of nineteen reachable public authorization servers advertised in discovery as of August 2026. The sample is biased against RAR by construction and says so. Includes the argument that RFC 9396 enforcement is custom by specification, and that the exception is a workflow engine, which owns its own action boundary.

- [**Typed grants and provenance in a durable execution engine**](typed-grants-in-a-durable-engine.md) — the design notes the delegated-identity proposal was cut down from, covering the three things that proposal dropped: how a runtime composes with an enterprise IdP protocol by being the attestation underneath it and terminating it at the edge, why a policy building block should abstract the question rather than the engine and leave relationship writes alone, and why in a durable workflow the activity signature *is* the typed transaction.

- [**Multi-tenant agentic workflows: a worked reference architecture**](multi-tenant-agentic-workflows.md) — one regulated multi-tenant use case driven out into layers, twelve named failure points, and an honest inventory of what a durable runtime already covers, which is more than the usual telling admits. Works out what the grant object holds, why the activity boundary asks three separate policy questions belonging in three different engines, and why step-up authorization is a durable-execution-shaped problem living in the wrong layer.

- [**Typed intent, open intent, and the limits of agent authorization**](typed-intent-and-containment.md) — the argument that the useful line runs between typed and open intent rather than between authorization and judgment: RFC 9396 binds a refund because a refund has fields, and binds nothing about "clean up the staging environment" because that has none. Covers why the dangerous failure is the quiet in-distribution one, and what credential brokering and taint tracking each stop short of.

## Proposals

- [**Delegated Identity and Token Exchange in Dapr**](dapr-delegated-identity-proposal.md) — draft proposal (targeting `dapr/proposals`) adding delegated authority to Dapr in three layers: a pluggable `sts` component type implementing RFC 8693 and its vendor dialects, a delegation context propagated across durable workflow boundaries the way trace context already is, and an `onBehalfOf` auth mode on the consumers that make authenticated outbound calls. The design constraint is that application and activity code stays byte-for-byte unchanged and no bearer token ever reaches the app process, the workflow payload, or the state store.

  The argument for why this belongs in a runtime rather than a gateway is the durable case: a workflow authorized on Tuesday, resumed three days later from a timer, must call an API as a user whose access token expired two days ago and who is not online to re-consent. What survives those three days cannot be a token; it has to be a non-secret delegation context from which a fresh token is minted at call time.

## Verification

- [**Verification report**](verification-report.md) — every falsifiable claim in the two documents above, checked against primary sources: repositories cloned and read at pinned commits, official documentation, and the relevant RFCs. It found three refuted claims, including one that reversed a conclusion, and it is published alongside the documents rather than folded silently into them.

## Conventions

Version-dependent claims are dated or pinned to a package version where it matters, because the answers move. Verified behavior is stated as verified; everything else is stated as an argument.
