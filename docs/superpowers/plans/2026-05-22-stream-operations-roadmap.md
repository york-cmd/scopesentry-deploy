# Stream Operations Roadmap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stabilize Redis Stream based scan scheduling for production rollout before expanding it to additional scan modules.

**Architecture:** Keep PortScan and SubdomainScan on the existing Redis Streams + Mongo chunk model. Add operational checks first, then add health summaries, task controls, node capacity governance, and finally evaluate more modules.

**Tech Stack:** Bash, Docker Compose, Redis Streams, MongoDB, Go/Gin, Vue 3, Element Plus.

---

## P0: Online Status Confirmation Script

**Status:** in progress

**Files:**
- Modify: `scripts/enable-stream-task.sh`
- Modify: `scripts/tests/enable_stream_task_test.sh`

**Deliverables:**
- `enable` keeps Stream as the default rollout path for PortScan and SubdomainScan.
- `status` prints service-side and scan-node-side Stream flags from compose/env/container runtime.
- `doctor` verifies:
  - server container has `STREAM_PORTSCAN_ENABLED=true`
  - server container has `STREAM_SUBDOMAIN_ENABLED=true`
  - scan node has `TASK_MODE=stream`
  - scan node has PortScan and SubdomainScan Stream enabled
  - bundled UI contains Subdomain Stream progress assets
  - Redis Stream keys are inspectable
  - Mongo `stream_task_chunks` is inspectable
- Missing `/apps/config/config.yaml` on scan nodes is explained as an expected pre-generated-config state when container env is present.
- Split-machine deployment is supported: server-only and scan-node-only machines should show warnings for the missing side, not hard fail.

**Verification:**
- `bash scripts/tests/enable_stream_task_test.sh`
- `bash -n scripts/enable-stream-task.sh scripts/tests/enable_stream_task_test.sh`
- `git diff --check -- scripts/enable-stream-task.sh scripts/tests/enable_stream_task_test.sh`

## P1: Stream Task Health Dashboard

**Status:** planned

**Server API scope:**
- Add a task-level Stream health endpoint that returns one object per stage: `SubdomainScan` and `PortScan`.
- Each stage summary returns:
  - `pending`
  - `queued`
  - `running`
  - `success`
  - `retrying`
  - `dlq`
  - `ignored`
  - `cancelled`
  - `blocked`
  - `stuck`
  - `leaseExpired`
  - `oldestRunningSeconds`
  - `lastFinishedAt`
  - `finishedLastMinute`
  - `finishedLastFiveMinutes`
- Add node aggregation by current chunk owner:
  - `node`
  - `running`
  - `retrying`
  - `lastStartedAt`
  - `leaseExpiringSoon`
- Keep existing per-task DLQ list APIs compatible.

**UI scope:**
- Extend `StreamChunkProgress.vue` instead of creating another task progress component.
- Show quick counts at the top.
- Add a compact table for running/stuck chunks.
- Add a compact table for node activity.
- Keep DLQ retry/ignore actions visible but move batch actions to P2.

**Why this comes before P2/P3:**
- It directly answers why a task ran for 10+ hours: no available node, slow node, lease expiry, DLQ block, or a plugin that keeps running.
- It gives operators evidence before they use control actions.

**Verification target:**
- Unit tests for summary aggregation.
- UI lint for changed task components.
- Manual check on one task with no chunks, one running task, and one DLQ task.

## P2: Task Control Capability

**Status:** planned

**Server API scope:**
- Add task-level Stream control state:
  - `running`
  - `paused`
  - `cancelling`
  - `cancelled`
- Add APIs:
  - pause Stream scheduling for a task
  - resume Stream scheduling for a task
  - cancel pending/queued chunks for a task
  - batch retry DLQ chunks
  - batch ignore DLQ chunks
  - release chunks owned by an offline node
- Reaper must respect paused/cancelled state.
- Continuation must not dispatch downstream stages while a task is paused or cancelling.

**UI scope:**
- Add task-level buttons in progress dialog:
  - pause
  - resume
  - cancel Stream chunks
  - retry all DLQ
  - ignore all DLQ
- Add confirmation dialogs for destructive actions.
- Show control state near the existing task status.

**Verification target:**
- Server tests for pause/resume/cancel state transitions.
- Server tests that cancelled chunks do not get requeued.
- UI lint for changed components.
- Manual flow: create chunks, pause, verify no new dispatch, resume, verify dispatch continues.

## P3: Node Capacity Governance

**Status:** planned

**Scan node scope:**
- Add explicit node capacity config:
  - max concurrent PortScan chunks
  - max concurrent SubdomainScan chunks
  - adaptive pull enabled
  - CPU high-water mark
  - memory high-water mark
- Make adaptive pull decisions observable in logs.
- Report current Stream runtime state with node heartbeat:
  - enabled stages
  - current running Stream chunks
  - per-stage concurrency limits
  - adaptive throttled or not

**Server/UI scope:**
- Show node Stream capacity in node management or dashboard.
- Surface whether a node is accepting new Stream chunks.
- Show per-node running chunk counts in P1 health dashboard.

**Verification target:**
- Scan-node tests for per-stage concurrency limiting.
- Scan-node tests for adaptive throttle decisions.
- Server/UI tests for node heartbeat fields.

## P4: Additional Stream Modules

**Status:** planned

**Candidate modules:**
- DirScan
- URLScan
- WebCrawler
- VulnerabilityScan

**Order recommendation:**
1. DirScan first, because target units can be split by URL/domain and dictionary/plugin with clearer retry boundaries.
2. URLScan/WebCrawler second, because crawler state and deduplication need careful continuation handling.
3. VulnerabilityScan last, because templates, side effects, and duplicate findings make retry semantics more complex.

**Preconditions before starting P4:**
- P1 health dashboard is deployed.
- P2 controls are deployed.
- P3 node capacity reporting is deployed or at least scan-node concurrency limits exist.
- At least one real production task has been observed end-to-end with PortScan and SubdomainScan Stream.

**Verification target:**
- Each new module gets its own design and implementation plan.
- Each new module must define chunk boundary, idempotency behavior, DLQ behavior, continuation behavior, and UI health summary before implementation.
