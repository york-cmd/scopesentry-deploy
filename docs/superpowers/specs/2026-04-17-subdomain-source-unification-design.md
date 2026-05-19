# Subdomain Source Unification Design

**Goal**

Unify subdomain discovery provenance across built-in plugins, hot plugins, and non-plugin/system sources so every discovered subdomain can be traced by compact numeric source IDs instead of overloaded `tags`.

**Constraints**

- `tags` returns to business-tag usage only and is no longer used for provenance.
- Old/test data does not need backfill or compatibility preservation.
- Asset-level provenance truth lives in a new `subdomain_source_summary` collection.
- All source types must participate: built-in plugins, hot plugins, and direct/system emitters.

**Approach**

Use three collections with `sourceRef int32` as the stable join key:

1. `discovery_sources`
   - Canonical source registry.
   - One row per discovery origin.
   - Contains display metadata and stable numeric `sourceRef`.
2. `subdomain_discovery_events`
   - Task-scoped raw discovery facts.
   - Unique by `taskId + sourceRef + host`.
   - Written at scan time for every discovered subdomain.
3. `subdomain_source_summary`
   - Asset-scoped provenance summary.
   - Unique by `rootDomain + host`.
   - Stores compact `sourceRefs []int32` so later reads do not depend on `tags`.

**Source Registry**

`discovery_sources` stores:

- `sourceRef`
- `sourceKey`
- `name`
- `module`
- `kind` (`builtin_plugin`, `custom_plugin`, `system`)
- optional `pluginHash`
- optional `isSystem`
- timestamps

`sourceKey` is the dedupe key. For plugins it is derived from `pluginHash`; for system emitters it is a reserved key like `system:SubdomainScan:direct-input`.

**Write Path**

1. Server ensures every plugin has a `sourceRef`.
2. Built-in scan plugins set both plugin identity and `sourceRef` on `SubdomainResult`.
3. Hot plugin bridge auto-injects source metadata into `SubdomainResult` before forwarding.
4. Direct/system subdomain emissions set a reserved system `sourceRef`.
5. Scan side writes:
   - one `subdomain_discovery_events` row per `taskId + sourceRef + host`
   - one `subdomain_source_summary` upsert per `rootDomain + host`, adding `sourceRef` with `$addToSet`

**Read Path**

Task comparison API reads `subdomain_discovery_events`, groups by `sourceRef`, and resolves display metadata from `discovery_sources`.

This keeps comparison results accurate for:

- built-in plugins
- hot plugins
- future system emitters

without falling back to `tags` or synthetic placeholders like `legacy-unattributed`.

**Compatibility**

- No backfill.
- Remove temporary legacy fallback once the new path is live.
- Existing stale test rows can be deleted manually if needed.

**Testing**

- Server tests for new model/index declarations and comparison aggregation by `sourceRef`.
- Scan tests for hot-plugin injection, system-source injection, and event/summary writes.
- Manual runtime check through `./devctl scan rebuild` and `./devctl restart`.
