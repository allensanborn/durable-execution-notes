# Durable execution notes

Working notes on durable-execution engines: how they actually behave, where their control surfaces differ, and which of those differences change a design decision.

## Notes

- [**Dapr Workflow vs. Temporal: where the gaps actually are**](dapr-workflow-vs-temporal.md) — both are log-based, event-sourced engines that recover by deterministic replay, so the differences are not in the core model. They are in execution control (Dapr has no activity timeouts and no heartbeat), versioning, payload ceilings, and history hygiene. Includes a summary table and a choosing-between-them section.

## Conventions

Version-dependent claims are dated or pinned to a package version where it matters, because the answers move. Verified behavior is stated as verified; everything else is stated as an argument.
