# Durable execution notes

Working notes on durable-execution engines: how they actually behave, where their control surfaces differ, and which of those differences change a design decision.

## Notes

- [**Dapr Workflow vs. Temporal: where the gaps actually are**](dapr-workflow-vs-temporal.md) — both are log-based, event-sourced engines that recover by deterministic replay, so the differences are not in the core model. They are in execution control (Dapr has no activity timeouts and no heartbeat), versioning, payload ceilings, and history hygiene. Includes a summary table and a choosing-between-them section.

## Proposals

- [**Delegated Identity and Token Exchange in Dapr**](dapr-delegated-identity-proposal.md) — draft proposal (targeting `dapr/proposals`) adding delegated authority to Dapr in three layers: a pluggable `sts` component type implementing RFC 8693 and its vendor dialects, a delegation context propagated across durable workflow boundaries the way trace context already is, and an `onBehalfOf` auth mode on the consumers that make authenticated outbound calls. The design constraint is that application and activity code stays byte-for-byte unchanged and no bearer token ever reaches the app process, the workflow payload, or the state store.

  The argument for why this belongs in a runtime rather than a gateway is the durable case: a workflow authorized on Tuesday, resumed three days later from a timer, must call an API as a user whose access token expired two days ago and who is not online to re-consent. What survives those three days cannot be a token; it has to be a non-secret delegation context from which a fresh token is minted at call time.

## Verification

- [**Verification report**](verification-report.md) — every falsifiable claim in the two documents above, checked against primary sources: repositories cloned and read at pinned commits, official documentation, and the relevant RFCs. It found three refuted claims, including one that reversed a conclusion, and it is published alongside the documents rather than folded silently into them.

## Conventions

Version-dependent claims are dated or pinned to a package version where it matters, because the answers move. Verified behavior is stated as verified; everything else is stated as an argument.
