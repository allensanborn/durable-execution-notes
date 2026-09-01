# Source of truth for every C4 view in this repository. The views are exported to Mermaid,
# post-processed by tools/structurizr-mermaid-clean.py, and embedded in the markdown documents;
# tools/build-diagrams.sh runs the whole chain. Do not hand-edit an exported or embedded diagram.
#
# Scope is deliberately unscoped: the subject genuinely is the interaction between several
# systems, so one landscape workspace is correct here even though `inspect` prefers one system
# per workspace. Anything tagged "Proposed" DOES NOT SHIP; it is design in these documents.

workspace "Agent authorization in a durable execution runtime" "Static structure behind the notes in this repository: what ships today in a Dapr-based agent platform, what Temporal does differently, and which pieces are proposed and do not exist." {

    # These two inspections are deliberately downgraded. The diagrams here are published by
    # embedding them into the repository's markdown documents, which are the documentation and
    # the decision record; there is no separate Structurizr docs tree or ADR log to point at.
    properties {
        "structurizr.inspection.model.softwaresystem.documentation" "info"
        "structurizr.inspection.model.softwaresystem.decisions" "info"
    }

    model {
        !impliedRelationships true

        operator = person "Human operator" "Triages one tenant's exception queue. The initiating principal whose authority a run carries."
        platformOp = person "Platform operator" "Has to render workflow history to answer a question, without holding a tenant's keys."

        group "Agent platform" {
            dapr = softwareSystem "Dapr-based agent platform" "Runs multi-tenant agent work as durable workflows, one sidecar per app-id." {
                app = container "Agent application" "Orchestrator, activity workers and agent loop. Every token today is handled by code in here." "Python or .NET, Dapr Agents" {
                    orchestrator = component "Workflow orchestrator" "Deterministic and replayed: no I/O, no clock, no LLM. Holds grants, never a token." "Dapr Workflow SDK"
                    activity = component "Activity worker" "The only place side effects live. Mints a token per use and returns the business result only." "Dapr Workflow SDK"
                    agentLoop = component "DurableAgent agent loop" "Memory tiers, tool calling, multi-agent orchestration. Implements no SPIFFE identity of its own." "Dapr Agents"
                    handRolled = component "Hand-rolled exchange and token cache" "Per-IdP branching, per-worker cache, expiry tracked by hand. Rebuilt in every application." "Application code"
                }
                sidecar = container "Dapr sidecar (daprd)" "Workflow engine, actors, state and MCP clients. Holds the workload SVID; the app cannot ask for one." "Go" {
                    wfengine = component "Workflow engine" "durabletask-go orchestration hosted as actors. Writes the append-only history." "Go, durabletask-go"
                    actorPath = component "Actor state path" "pkg/actors/state. Calls the store's Multi and Get directly and never imports pkg/encryption." "Go"
                    stateApi = component "State building block API" "The /v1.0/state HTTP and gRPC handlers. The only caller of the encryption helper." "Go"
                    stateCrypto = component "State encryption helper" "AES-GCM with keys from a secret store. Wraps values at the state API, not at the store object." "Go, pkg/encryption"
                    mcpClient = component "MCP client and auth round-tripper" "Invokes tools for an MCPServer resource and attaches an app-identity credential when configured." "Go"
                    delegation = component "Delegation context" "PROPOSED. Non-secret subject, grant reference, scopes and act chain, carried like trace context. The subject token is never persisted." "Go" "Proposed"
                    obo = component "onBehalfOf resolver" "PROPOSED. At call time: read the context, intersect scopes, check the audience allowlist, mint, inject." "Go" "Proposed"
                    tokenCache = component "Token cache" "PROPOSED. Per-sidecar, in memory only, singleflight, TTL capped below token expiry." "Go" "Proposed"
                    stsComponent = component "sts component" "PROPOSED. Pluggable RFC 8693 client authenticating as the sidecar's own JWT-SVID. No static client secret." "Go, components-contrib" "Proposed"
                    policyBlock = component "policy building block" "PROPOSED. Abstracts the question, check(principal, action, resource, context, grant), not the engine, and not relationship writes." "Go, components-contrib" "Proposed"
                    enforcementHook = component "Before-activity enforcement hook" "PROPOSED. Runs the free local gates first, then the network ones. Returns allow, deny or escalate." "Go" "Proposed"
                }
                store = container "State store" "Workflow history, actor state and application state all land here." "Redis, PostgreSQL, CosmosDB or DynamoDB" "Database"
            }
            sentry = softwareSystem "Dapr Sentry" "CA and, since 1.16, an OIDC issuer. Issues X.509 and JWT-SVIDs bound to a per-app-id SPIFFE ID." "Platform"
        }

        group "Alternative durable engine" {
            temporal = softwareSystem "Temporal" "Dedicated durable-execution platform. Same replay core, different control surfaces." "Platform" {
                tWorker = container "Worker" "Runs workflow and activity code. Its Data Converter and Payload Codec encrypt payloads in-process." "Temporal SDK plus your codec"
                tService = container "Temporal service" "Persists the event history. Stores ciphertext and never holds your keys." "Temporal Server"
                tCodec = container "Codec server" "You run it. /encode, /decode, /download. The platform gets a decode service, not a key." "Your service"
                tUi = container "Web UI and CLI" "Cannot decrypt anything itself. Round-trips payloads through your codec server." "Temporal Web, Temporal CLI"
            }
        }

        group "Identity and authorization" {
            sts = softwareSystem "Authorization server / STS" "Keycloak 26.2+, ZITADEL, Auth0, Authlete. Issues the composite token carrying the act chain." "External"
            entra = softwareSystem "Microsoft Entra ID" "Does not implement RFC 8693. On-behalf-of is RFC 7523 plus requested_token_use, no actor vocabulary." "External"
            enterpriseIdp = softwareSystem "Enterprise IdP" "Okta Cross App Access and Agent SSO. Governs agent-to-app access at the edge, and cannot see an orchestration boundary." "External"
            gateway = softwareSystem "Egress and agent gateway" "agentgateway or Kong AI Gateway. Request-scoped token exchange and credential injection; under the gateway-custody rule it holds the credential, not the agent." "External"
            pdp = softwareSystem "Policy decision point" "OPA, Cerbos or Cedar. Stateless decision engines holding per-tenant contract policy data." "External"
            relationshipStore = softwareSystem "Relationship store" "OpenFGA or SpiceDB. Zanzibar-lineage stores answering entitlement through a Check API." "External"
        }

        group "Targets" {
            mcp = softwareSystem "MCP server" "Tool surface. Its specification forbids transiting tokens not issued for it." "External"
            downstream = softwareSystem "Downstream API" "Claims, payments and SaaS. Its own per-user authorization is what delegation makes work." "External"
            llm = softwareSystem "Model provider" "Everything it returns to an activity is untrusted content." "External"
        }

        # --- people
        operator -> app "Starts and triages agent runs in" "HTTPS"
        operator -> enterpriseIdp "Authenticates to" "OIDC"
        platformOp -> wfengine "Reads workflow history through, in the clear" "HTTP"
        platformOp -> tUi "Inspects workflow history through" "HTTPS"

        # --- what ships today, Dapr side
        app -> sidecar "Schedules workflows and activities through" "gRPC over localhost"
        orchestrator -> wfengine "Schedules activities and child workflows through" "gRPC"
        activity -> handRolled "Obtains a downstream token from" "in-process call"
        agentLoop -> orchestrator "Drives its tool-calling loop as" "in-process call"
        handRolled -> sts "Performs a hand-rolled exchange against" "RFC 8693 over HTTPS"
        handRolled -> entra "Branches to a second request shape for" "RFC 7523 over HTTPS"
        activity -> downstream "Calls, with the token it minted and never returns" "HTTPS"
        activity -> llm "Calls models from inside an activity" "HTTPS"
        wfengine -> actorPath "Persists history through" "in-process call"
        actorPath -> store "Writes history to, in the clear" "Multi and Get, no encryption"
        app -> stateApi "Writes application state through" "HTTP or gRPC"
        stateApi -> stateCrypto "Wraps every value through" "TryEncryptValue and TryDecryptValue"
        stateCrypto -> store "Writes AES-GCM ciphertext to" "state component API"
        mcpClient -> mcp "Invokes tools on, attaching an app-identity credential when configured" "JSON-RPC over HTTPS"
        sidecar -> downstream "Invokes HTTPEndpoints and HTTP bindings on" "HTTPS"
        sidecar -> sentry "Fetches its X.509 and JWT-SVIDs from" "gRPC over mTLS"
        entra -> sentry "Validates runtime-issued JWT-SVIDs against, as a relying party" "OIDC discovery and JWKS"
        app -> gateway "Can instead make credential-free egress calls through" "HTTPS"
        gateway -> sts "Exchanges tokens with" "RFC 8693 over HTTPS"
        gateway -> downstream "Calls with the injected credential" "HTTPS"
        gateway -> mcp "Calls with the injected credential" "HTTPS"
        enterpriseIdp -> gateway "Issues the enterprise agent-access token presented at" "OAuth 2.0"

        # --- Temporal side, what ships today
        tWorker -> tService "Persists codec-encrypted history to" "gRPC"
        tWorker -> downstream "Calls from inside an activity" "HTTPS"
        tWorker -> llm "Calls models from inside an activity" "HTTPS"
        tUi -> tService "Reads raw event history from" "gRPC and HTTP"
        tUi -> tCodec "Decodes payloads for display through" "HTTP /decode"

        # --- proposed
        wfengine -> delegation "PROPOSED. Establishes and propagates, to activities and child workflows" "in-process call" "Proposed"
        delegation -> store "PROPOSED. Persists everything except the subject token with the instance" "actor state" "Proposed"
        mcpClient -> obo "PROPOSED. Resolves an onBehalfOf auth mode through" "in-process call" "Proposed"
        obo -> delegation "PROPOSED. Reads the subject, grant reference and act chain from" "in-process call" "Proposed"
        obo -> tokenCache "PROPOSED. Checks and fills, keyed on subject, audience, effective scopes and act chain" "in-process call" "Proposed"
        obo -> stsComponent "PROPOSED. Requests an exchange from, on a cache miss" "component API" "Proposed"
        stsComponent -> sts "PROPOSED. Exchanges a grant for a downstream token with, authenticating as the sidecar's SVID" "RFC 8693 over HTTPS" "Proposed"
        stsComponent -> entra "PROPOSED. Speaks the on-behalf-of dialect to, which is why the abstraction exists" "RFC 7523 over HTTPS" "Proposed"
        wfengine -> enforcementHook "PROPOSED. Calls before every activity, with the typed action and the grant" "in-process call" "Proposed"
        enforcementHook -> policyBlock "PROPOSED. Asks the network gates through" "component API" "Proposed"
        enforcementHook -> operator "PROPOSED. Suspends the run and raises an approval request to, on escalate" "external event" "Proposed"
        policyBlock -> relationshipStore "PROPOSED. Asks entitlement of" "Check API over gRPC" "Proposed"
        policyBlock -> pdp "PROPOSED. Asks per-tenant contract policy of" "decision API over HTTP" "Proposed"
    }

    views {
        systemLandscape "Landscape" "Level 1. Who participates in agent authorization around a durable engine, and which participants are only proposed." {
            title "System landscape: agent authorization around a durable execution engine"
            include *
            autolayout tb 260 130
        }

        container dapr "Containers" "Level 2. Where a credential may live in a Dapr agent platform: which container holds one, which merely routes one, and which is only proposed." {
            title "Container view: Dapr-based agent platform"
            include *
            exclude temporal
            # The policy engines and the egress gateway are landscape-level collaborators; drawing
            # them here only adds crossing edges. They have their own views.
            exclude pdp
            exclude relationshipStore
            exclude gateway
            autolayout tb 260 130
        }

        component app "TodaysBaseline" "Level 3, inside the application. Where token handling lives today, with nothing in the runtime to carry it." {
            title "Component view: Agent application - where token handling lives today"
            include orchestrator activity agentLoop handRolled wfengine sts entra downstream
            autolayout tb 260 130
        }

        component sidecar "HistoryEncryption" "Level 3, inside the sidecar. Which write path the state encryption helper is on, and which one workflow history takes." {
            title "Component view: Dapr sidecar (daprd) - the state encryption boundary"
            include app stateApi stateCrypto actorPath wfengine store platformOp
            autolayout tb 260 130
        }

        component sidecar "DelegatedIdentity" "Level 3, inside the sidecar. The proposed call-time resolution path from a delegation context to an injected token." {
            title "Component view: Dapr sidecar (daprd) - proposed delegated-identity resolution"
            include wfengine delegation obo tokenCache stsComponent mcpClient store sts entra mcp
            autolayout tb 260 130
        }

        component sidecar "PolicyBlock" "Level 3, inside the sidecar. The proposed enforcement hook and the two policy paradigms one building block has to serve." {
            title "Component view: Dapr sidecar (daprd) - proposed policy building block"
            include wfengine enforcementHook policyBlock pdp relationshipStore operator
            autolayout tb 260 130
        }

        container temporal "TemporalCodec" "Level 2. How a payload codec plus a codec server gives tooling a decode path without giving it a key." {
            title "Container view: Temporal - the payload codec path"
            include *
            exclude downstream
            exclude llm
            autolayout tb 260 130
        }

        styles {
            element "Person" {
                shape person
            }
            element "Database" {
                shape cylinder
            }
            element "External" {
                background #8a8a8a
                color #ffffff
            }
            element "Platform" {
                background #6b7f9e
                color #ffffff
            }
            # Proposed things do not exist. They must never read as shipping code, so the tag
            # carries the distinction three ways: a dashed orange border, orange text, and a
            # description beginning "PROPOSED." The description is the channel that survives any
            # exporter; see tools/structurizr-mermaid-clean.py for what the Mermaid export drops.
            element "Proposed" {
                background #ffffff
                stroke #b3591a
                strokeWidth 4
                border dashed
                color #b3591a
            }
            relationship "Proposed" {
                style dashed
                color #b3591a
            }
        }
    }

    configuration {
        scope none
    }
}
