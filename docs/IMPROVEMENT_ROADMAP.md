# zkuzu Improvement Roadmap

This document outlines the improvements needed to bring zkuzu up to the maturity level of pg.zig and zqlite, based on a comprehensive comparison of the three libraries.

Status summary (current code review):
- Priority 1 (Memory Management) – implemented in zkuzu.
- Priority 2 (Enhanced Error Handling) – implemented in zkuzu with `KuzuError`, connection `err`, and tests.
- Priority 3 (Connection State) – implemented: lightweight guards replace enum state; overlapping queries are forbidden; transaction flag tracks active TX; recovery simplified and test‑covered.
- Priority 4 (Type-Safe Accessors) – implemented via `Row.get(T, idx|name)` and helpers.
- Priority 5 (Comprehensive Testing) – largely implemented; several targeted scenarios remain.
- Priorities 6–8 – next areas of focus.

## Priority 1: Memory Management - Arena Allocator Pattern

### Overview
Adopt pg.zig's arena allocator pattern for automatic memory cleanup and prevention of memory leaks. Each QueryResult should own an arena that gets cleaned up on deinit().

### Reference Implementation
- pg.zig/src/result.zig:17 - Result struct with `_arena: *ArenaAllocator` field
- pg.zig/src/result.zig:31-54 - Result.deinit() showing arena cleanup pattern
- pg.zig/src/stmt.zig:53-54 - Arena initialization pattern
- pg.zig/src/conn.zig:276 - Creating arena for describe operations

### Implementation Checklist

- [x] src/query_result.zig
  - Add `_arena: *ArenaAllocator` field to QueryResult struct (ref: pg.zig/src/result.zig:17)
  - Initialize arena in QueryResult.init() (ref: pg.zig/src/stmt.zig:53-54)
  - Use arena for all string allocations (column names, string values)
  - Clean up arena in QueryResult.deinit() (ref: pg.zig/src/result.zig:50-53)

- [x] src/conn.zig
  - Pass allocator to QueryResult for arena creation
  - Remove manual string duplication in error paths
  - Use arena for temporary allocations during query execution (ref: pg.zig/src/conn.zig:276)

- [x] src/prepared_statement.zig
  - Update PreparedStatement.execute() to pass allocator for arena
  - Ensure parameter bindings use appropriate lifetime management

- [x] src/pool.zig
  - Ensure pooled connections properly manage allocator contexts
  - Update Transaction helper to work with arena patterns

### Testing
- [x] src/tests/query_result.zig
  - Add tests for memory leak detection
  - Test large result sets for proper cleanup
  - Test error paths for no leaks

## Priority 2: Enhanced Error Handling

### Overview
Introduce structured error reporting tailored to Kuzu’s current C API. Kuzu exposes a success/failure state and an error message string; it does not provide PostgreSQL‑style protocol codes nor SQLite’s exhaustive numeric codes. The goals are:
- Standardize error capture with a `KuzuError` carrying the message, operation context, and a coarse category.
- Store the last detailed error on the connection for inspection and logging.
- Integrate with existing state handlers so callers consistently receive both an error union and an inspectable `Conn.err`.

This is pragmatic: we won’t fabricate PG/SQLite codes. If Kuzu later adds richer fields/codes, `KuzuError` can extend without breaking the API.

### Reference (Conceptual) Implementations
- pg.zig/src/conn.zig – `err` and `_err_data` ownership pattern on the connection.
- pg.zig/src/proto/error.zig – Example of a structured error object (conceptual inspiration only).
- zqlite/src/zqlite.zig – Broad error categories; use as inspiration for categorization, not a 1:1 mapping.

### Design
- `KuzuError` fields (owned where noted):
  - `op: enum { connect, query, prepare, execute, bind, config, transaction }`
  - `category: enum { argument, constraint, transaction, connection, timeout, interrupt, memory, unknown }`
  - `message: []u8` (owned copy of Kuzu’s message string)
  - `detail: ?[]u8`, `hint: ?[]u8` (reserved for future Kuzu fields; null for now)
  - `code: ?[]const u8` (optional string code if Kuzu adds one later)
  - `raw: ?[]u8` (optional owned raw payload, if available)

- Creation helpers:
  - `KuzuError.init(allocator, op, message)` – copies `message`, defaults `category = .unknown`.
  - `KuzuError.categorize()` – heuristics from message (e.g., contains “timeout”, “interrupt”, “constraint”, “transaction”, etc.).
  - `KuzuError.deinit()` – frees owned fields.

- Connection integration:
  - Add `Conn.err: ?KuzuError` and `Conn._err_data: ?[]u8`.
  - Add `Conn.setError(op, msg: []const u8)` and `Conn.clearError()`; keep `last_error_message` for backward compatibility.
  - Populate `err` on all failure paths (query/prepare/execute/config), calling `categorize()`.
  - Add `Conn.lastError() -> ?*const KuzuError`.

- Result/statement integration:
  - When a `QueryResult` indicates failure, fetch the message, call `conn.setError(.query, msg)`, then return the error union.
  - In `PreparedStatement` binds/execute, use the state handler message to build `KuzuError` with `op = .bind`/`.execute`.

### Implementation Checklist

- [x] src/errors.zig
  - Add `KuzuError` with fields and `init`, `categorize`, `deinit` helpers.
  - Keep the `Error` error set minimal for flow control (e.g., `QueryFailed`, `PrepareFailed`, `ExecuteFailed`, `InvalidArgument`, `Unknown`).

- [x] src/conn.zig
  - Add `err: ?KuzuError` and `_err_data: ?[]u8`.
  - Implement `setError`, `clearError`, and `lastError()`; ensure error is populated on all failure paths.

- [x] src/query_result.zig
  - On failed result, set `Conn.err` with `op = .query` and propagate.
  - Ensure any borrowed error strings are duplicated before free.

- [x] src/prepared_statement.zig
  - For bind/execute failures, build `KuzuError` from fetched messages and store on `Conn`.

### Testing
- [x] src/tests/errors.zig
  - Simulate failures in `query`, `prepare`, `execute`, and config methods; assert `Conn.err` has correct `op` and a reasonable `category`.
  - Verify error message preservation and ownership (no leaks, no UAF).
  - Confirm `clearError()` resets state; `lastErrorMessage()` remains backward compatible.

## Priority 3: Connection State Management

### Overview
Implement a proper state guard for connection lifecycle, with a simpler, Kuzu‑aligned approach.

Current implementation uses a full state machine with mutex protection and automatic recovery, and tests assert state transitions. We plan to migrate to lightweight guards better aligned with Kuzu semantics.

### Implementation Checklist

- [ ] Replace `.state` machine with lightweight guards: `in_result: bool`, `transaction_active: bool`, and a mutex.
- [ ] Enforce no nested queries while a result is active; clear flag on `QueryResult.deinit()`.
- [ ] Toggle `transaction_active` in `beginTransaction/commit/rollback`.
- [ ] Update pool validation to respect lightweight busy checks.
- [ ] Update tests to remove strong coupling to the old state enum.

### Testing
- [ ] Adjust `src/tests/conn.zig` to validate guard behavior and recovery.

## Priority 4: Type-Safe Value Access

### Overview
Implement compile-time type checking for value getters, reducing runtime errors.

### Reference Implementation
- pg.zig/src/result.zig:250-275 - Generic get() method with compile-time type handling
- pg.zig/src/result.zig:252-271 - Type switch handling optionals and custom types
- pg.zig/src/result.zig:277-281 - getCol() by name implementation
- pg.zig/src/lib.zig:269 - assertNotNull helper

### Implementation Checklist

- [x] src/query_result.zig / Row
  - Implement generic `Row.get(comptime T: type, index: usize) !T` with compile-time validation and nullable support.
  - Provide clear type mismatch/overflow errors.

- [x] src/value.zig
  - Comprehensive value type system and safe conversions.
  - Support complex types (arrays/lists, structs/nodes/rels/maps, recursive rels).

- [ ] Documentation
  - [x] Examples use type-safe accessors (see `examples/basic.zig`, `examples/prepared.zig`).
  - [ ] Document type mapping between Kuzu logical types and Zig types.

### Testing
- [x] src/tests/query_result.zig
  - Scalars, nullables, lists, conversion bounds, and mismatch detection.

## Priority 5: Comprehensive Testing

### Overview
Expand test coverage to match pg.zig's comprehensive testing approach.

### Reference Implementation
- zqlite/src/pool.zig:110-142 - Pool concurrency test pattern
- zqlite/src/pool.zig:126-132 - Multi-thread test spawning
- zqlite/src/pool.zig:119-122 - Test callbacks for connection setup
- pg.zig/src/t.zig - Test helper utilities

### Implementation Checklist

- [x] src/tests/integration.zig
  - End-to-end workflow and multi-threaded usage via pool.
  - Large dataset timing sample.

- [x] src/tests/edge_cases.zig
  - Null handling, empty results, max parameter stress.
  - Connection failure/validation/recovery.

- [x] src/tests/transactions.zig
  - Nested begin failure, rollback scenarios, concurrent pool transactions, single-connection exhaustion.

- [x] src/tests/pool.zig
  - Pool basics, helpers, exhaustion, query via pool.

- [x] src/tests/errors.zig
  - KuzuError propagation across ops; clear/reset lifecycle.

- [x] src/tests/conn.zig
  - Connection config knobs; state transitions and recovery; pool validation under concurrency.

- [x] test_runner.zig
  - Custom runner with per-test leak check and timing summary.

- [ ] Add targeted scenarios
  - Interrupt/timeout behavior under load.
  - Constraint violation paths.
  - Pool `cleanupIdle` lifecycle.
  - Additional value conversions: blob/uuid/decimal/internal_id coverage.
  - Regression hunt for pool validation and structured error tests after Zig 0.15.1 migration.

## Priority 6: API Documentation

### Overview
Add comprehensive inline documentation for all public APIs.

### Implementation Checklist

- [ ] **All public functions in src/**
  - Many doc comments exist; complete coverage and examples still needed.

- [x] **README.md**
  - API overview/reference, troubleshooting, performance tips, migration guide present.

- [x] **examples/**
  - Advanced examples for prepared statements, pooling, transactions, performance.

## Priority 7: Additional Features

### Overview
Add features that exist in mature libraries but are missing in zkuzu.

### Reference Implementation
- pg.zig/src/metrics.zig:5-21 - Metrics structure and counters
- pg.zig/src/metrics.zig:32-56 - Metric collection functions
- pg.zig/src/pool.zig:200-260 - Reconnector with health checks
- zqlite/src/pool.zig:119-122 - Connection callbacks pattern

### Implementation Checklist

- [ ] **Metrics and Instrumentation**
  - Add query execution metrics (ref: pg.zig/src/metrics.zig:32-34)
  - Connection pool statistics (ref: pg.zig/src/metrics.zig:36-42)
  - Memory usage tracking (ref: pg.zig/src/metrics.zig:44-56)
  - Performance profiling hooks

- [ ] **Async Support Investigation**
  - Research feasibility of async operations
  - Design async API if applicable
  - Implement non-blocking queries

- [ ] **Advanced Pool Features**
  - Connection warming (ref: zqlite/src/pool.zig:161-176)
  - Idle connection timeout
  - Max lifetime configuration
  - Connection validation callbacks (ref: zqlite/src/pool.zig:119-122)
  - Automatic reconnection (ref: pg.zig/src/pool.zig:224-260)

- [ ] **Query Builder** (optional)
  - Type-safe Cypher query builder
  - Parameterized query templates
  - Query composition utilities

## Priority 8: Build System Enhancements

### Overview
Improve build configuration and dependency management.

### Implementation Checklist

- [ ] **build.zig**
  - Add debug/release configuration options
  - Implement feature flags
  - Add installation targets
  - Improve error messages for missing dependencies

- [ ] **build.zig.zon**
  - Keep Kuzu version updated
  - Add versioning strategy
  - Document upgrade process

## Implementation Strategy

### Phase 1: Foundation (Priorities 1-3)
Timeline: 2-3 weeks
- Focus on memory management, error handling, and state management
- These form the foundation for other improvements
- Must be done before other changes to avoid rework

### Phase 2: Type Safety and Testing (Priorities 4-5)
Timeline: 2 weeks
- Build on the solid foundation from Phase 1
- Improve developer experience and reliability
- Ensure no regressions with comprehensive tests

### Phase 3: Documentation and Polish (Priorities 6-7)
Timeline: 1-2 weeks
- Document all improvements
- Add nice-to-have features
- Prepare for wider adoption

### Phase 4: Advanced Features (Priority 8)
Timeline: Ongoing
- Implement based on user feedback
- Keep pace with Kuzu updates
- Maintain compatibility

## Success Metrics

- [ ] Zero memory leaks in all test scenarios
- [ ] 90%+ test coverage
- [ ] All examples run without warnings
- [ ] Error messages provide actionable information
- [ ] Pool handles connection failures gracefully
- [ ] Type mismatches caught at compile time where possible
- [ ] Performance comparable to direct C API usage
- [ ] Documentation for every public API

## Notes

- Each checklist item should result in a focused PR
- Maintain backward compatibility where possible
- Add deprecation notices for breaking changes
- Consider creating a v2 branch for major changes
- Regular benchmarking against C API performance
