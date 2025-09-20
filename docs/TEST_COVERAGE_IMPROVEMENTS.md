# zkuzu Test Coverage Improvement Plan

This document summarizes current coverage and lists targeted additions to reach comprehensive coverage comparable to pg.zig/zqlite.

## Current Coverage Summary

- [x] Database + Connection Basics
  - Open/close database, create connection
  - Config knobs: `setTimeout`/`getMaxThreads`/`setMaxThreads`
  - Connection state transitions and recovery
  - Files: `src/tests/database.zig`, `src/tests/conn.zig`

- [x] Query Execution and Results
  - Exec vs query; result iteration
  - Result metadata: count/name/index/type
  - Iterator reset and arena-backed string lifetimes
  - Generic `Row.get(T, idx|name)`, nullables, lists, conversions, mismatches
  - Files: `src/tests/query_result.zig`

- [x] Prepared Statements
  - Prepare, bind (common types), execute
  - Error paths covered via errors tests
  - Files: `src/tests/prepared_statement.zig`, `src/tests/errors.zig`

- [x] Error Handling
  - `KuzuError` across ops (query/prepare/bind/execute/config)
  - `lastError()`/`lastErrorMessage()`, `clearError()`
  - Files: `src/tests/errors.zig`

- [x] Transactions
  - Manual begin/commit/rollback
  - Nested begin fails and recovery
  - Rollback discards changes
  - Concurrent pool transactions; single-connection exhaustion
  - Files: `src/tests/transactions.zig`

- [x] Connection Pool
  - Acquire/release, stats, query via pool
  - `withConnection`/`withTransaction` helpers
  - Concurrency validation
  - Files: `src/tests/pool.zig`, `src/tests/conn.zig`

- [x] Integration Workflows
  - E2E setup/queries
  - Multi-threaded writes via pool
  - Large dataset timing sample
  - Files: `src/tests/integration.zig`

- [x] Test Runner
  - Per-test leak check and timings
  - File: `test_runner.zig`

## Gaps and TODOs

- [ ] Interrupt and Timeout
  - Start long-running query in a thread; call `conn.interrupt()`; assert timely failure and `KuzuError.category` timeout/interrupt when applicable.
  - Validate `setTimeout()` under load and categorize errors suitably.

- [ ] Constraint Violations
  - Primary key/unique constraint violation paths; ensure `KuzuError.category == .constraint` when message contains relevant tokens.

- [ ] Pool Lifecycle
  - Test `cleanupIdle` closes idle connections and maintains consistency of stats.
  - Health check behavior under failure/replacement.
  - Reproduce and fix current `pool validates and handles concurrent usage` regression under Zig 0.15.1.

- [ ] Value Conversions (Additional)
  - Add targeted coverage for:
    - `Row.getBlob`/`copyBlob`
    - `Row.getUuid`/`copyUuid`
    - `Row.getDecimalString`/`copyDecimalString`
    - `Row.getInternalId`
    - Value conversions: `toBlob`, `toUuid`, `toDecimalString`, `toInternalId`, date/timestamp/interval variants

- [ ] Negative/Edge Scenarios
  - OOB column index access → `Error.TypeMismatch`/`InvalidColumn` where applicable.
  - Int conversion overflow paths across more widths (u16/u32/u64, i16/i32/i64).

- [x] Connection State Refactor (completed)
  - Replaced enum assertions with behavior checks (busy result, TX guard).
  - Added overlapping query guard test and TX-while-busy test.
  - Validated recovery paths; `edge: connection failure and recovery` passes.

## Recommended Test Additions (sketches)

- Interrupt/timeout behavior
  - Spawn a worker running a synthetic long query; invoke `interrupt()` and expect query failure within a time budget.

- Constraint violations
  - Create a table with PK; attempt duplicate insert; assert `KuzuError.category == .constraint`.

- Pool `cleanupIdle`
  - Acquire/release several connections; sleep beyond threshold; call `cleanupIdle()`; assert reduced total and correct stats.

- Value conversions (targeted)
  - Create rows with blob/uuid/decimal/internal_id fields; verify getters and conversions; test copy variants.

## Implementation Strategy

1) Add tests incrementally in existing files to keep structure stable.
2) Use util helpers (`src/tests/util.zig`) for DB fixtures and timers to avoid duplication.
3) For scenarios requiring longer wall-clock behavior (interrupt/timeout), keep thresholds conservative to avoid flakiness.
