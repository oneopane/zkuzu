# zkuzu Improvement Roadmap

This document outlines the improvements needed to bring zkuzu up to the maturity level of pg.zig and zqlite, based on a comprehensive comparison of the three libraries.

## Priority 1: Memory Management - Arena Allocator Pattern

### Overview
Adopt pg.zig's arena allocator pattern for automatic memory cleanup and prevention of memory leaks. Each QueryResult should own an arena that gets cleaned up on deinit().

### Reference Implementation
- **pg.zig/src/result.zig:17** - Result struct with `_arena: *ArenaAllocator` field
- **pg.zig/src/result.zig:31-54** - Result.deinit() showing arena cleanup pattern
- **pg.zig/src/stmt.zig:53-54** - Arena initialization pattern
- **pg.zig/src/conn.zig:276** - Creating arena for describe operations

### Implementation Checklist

- [x] **src/query_result.zig**
  - Add `_arena: *ArenaAllocator` field to QueryResult struct (ref: pg.zig/src/result.zig:17)
  - Initialize arena in QueryResult.init() (ref: pg.zig/src/stmt.zig:53-54)
  - Use arena for all string allocations (column names, string values)
  - Clean up arena in QueryResult.deinit() (ref: pg.zig/src/result.zig:50-53)

- [x] **src/conn.zig**
  - Pass allocator to QueryResult for arena creation
  - Remove manual string duplication in error paths
  - Use arena for temporary allocations during query execution (ref: pg.zig/src/conn.zig:276)

- [x] **src/prepared_statement.zig**
  - Update PreparedStatement.execute() to pass allocator for arena
  - Ensure parameter bindings use appropriate lifetime management

- [x] **src/pool.zig**
  - Ensure pooled connections properly manage allocator contexts
  - Update Transaction helper to work with arena patterns

### Testing
- [x] **src/tests/query_result.zig**
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
- **pg.zig/src/conn.zig** – `err` and `_err_data` ownership pattern on the connection.
- **pg.zig/src/proto/error.zig** – Example of a structured error object (conceptual inspiration only).
- **zqlite/src/zqlite.zig** – Broad error categories; use as inspiration for categorization, not a 1:1 mapping.

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

- [x] **src/errors.zig**
  - Add `pub const KuzuError` with fields and `init`, `categorize`, `deinit` helpers.
  - Keep the `Error` error set minimal for flow control (e.g., `QueryFailed`, `PrepareFailed`, `ExecuteFailed`, `InvalidArgument`, `Unknown`).

- [x] **src/conn.zig**
  - Add `err: ?KuzuError` and `_err_data: ?[]u8`.
  - Implement `setError`, `clearError`, and `lastError()`; ensure error is populated on all failure paths.

- [x] **src/query_result.zig**
  - On failed result, set `Conn.err` with `op = .query` and propagate.
  - Ensure any borrowed error strings are duplicated before free.

- [x] **src/prepared_statement.zig**
  - For bind/execute failures, build `KuzuError` from fetched messages and store on `Conn`.

### Testing
- [x] **src/tests/errors.zig**
  - Simulate failures in `query`, `prepare`, `execute`, and config methods; assert `Conn.err` has correct `op` and a reasonable `category`.
  - Verify error message preservation and ownership (no leaks, no UAF).
  - Confirm `clearError()` resets state; `lastErrorMessage()` remains backward compatible.

### Notes
- Do not emulate PostgreSQL/SQLite error models without upstream support. Extend `KuzuError` if/when Kuzu exposes richer error details.

## Priority 3: Connection State Management

### Overview
Implement a proper state machine for connection lifecycle, similar to pg.zig's approach.

### Reference Implementation
- **pg.zig/src/conn.zig:64-75** - State enum definition
- **pg.zig/src/conn.zig:173,355,393,459-461** - State transitions
- **pg.zig/src/conn.zig:454,477,502** - Setting fail state on errors
- **pg.zig/src/pool.zig:200-260** - Reconnector for failed connections

### Implementation Checklist

- [x] **src/conn.zig**
  - Add `state: State` enum field with states: idle, in_transaction, in_query, failed (ref: pg.zig/src/conn.zig:64-75)
  - Implement state transitions for all operations (ref: pg.zig/src/conn.zig:355,393,459)
  - Add state validation before operations
  - Set fail state on errors (ref: pg.zig/src/conn.zig:454,477,502)
  - Implement automatic recovery from failed state

- [x] **src/pool.zig**
  - Check connection state before returning from pool
  - Implement health check mechanism (ref: pg.zig/src/pool.zig:200-260)
  - Add automatic reconnection for failed connections
  - Track connection statistics

- [x] Implementation note
  - Connection validation and reset are implemented on `Conn` (`validate()`, `recover()`) and integrated into the pool rather than on `Database`. No additional `Database` wrappers are required.

### Testing
- [x] **src/tests/conn.zig**
  - Test state transitions
  - Test recovery from failed states
  - Test concurrent state management

## Priority 4: Type-Safe Value Access

### Overview
Implement compile-time type checking for value getters, reducing runtime errors.

### Reference Implementation
- **pg.zig/src/result.zig:250-275** - Generic get() method with compile-time type handling
- **pg.zig/src/result.zig:252-271** - Type switch handling optionals and custom types
- **pg.zig/src/result.zig:277-281** - getCol() by name implementation
- **pg.zig/src/lib.zig:269** - assertNotNull helper

### Implementation Checklist

- [x] **src/query_result.zig**
  - Implement generic `get(comptime T: type, index: usize) !T` method (ref: pg.zig/src/result.zig:250)
  - Add compile-time type validation (ref: pg.zig/src/result.zig:252-271)
  - Provide better type mismatch error messages
  - Support nullable types properly (ref: pg.zig/src/result.zig:253-258)

- [x] **src/value.zig** (new file)
  - Create comprehensive value type system
  - Implement type conversions with safety checks
  - Add support for complex types (arrays, structs, maps)

- [x] **Examples and Documentation**
  - Update examples to use type-safe accessors
  - Document type mapping between Kuzu and Zig

### Testing
- [x] **src/tests/query_result.zig**
  - Test all type conversions
  - Test type mismatch detection
  - Test nullable handling

## Priority 5: Comprehensive Testing

### Overview
Expand test coverage to match pg.zig's comprehensive testing approach.

### Reference Implementation
- **zqlite/src/pool.zig:110-142** - Pool concurrency test pattern
- **zqlite/src/pool.zig:126-132** - Multi-thread test spawning
- **zqlite/src/pool.zig:119-122** - Test callbacks for connection setup
- **pg.zig/src/t.zig** - Test helper utilities

### Implementation Checklist

- [x] **src/tests/integration.zig** (new file)
  - End-to-end workflow tests
  - Multi-threaded connection tests (ref: zqlite/src/pool.zig:126-132)
  - Large dataset handling tests
  - Performance benchmarks

- [x] **src/tests/edge_cases.zig** (new file)
  - Null value handling
  - Empty result sets
  - Maximum parameter limits
  - Connection loss scenarios

- [x] **src/tests/transactions.zig** (new file)
  - Nested transaction behavior
  - Rollback scenarios
  - Concurrent transaction tests (ref: zqlite/src/pool.zig:149-157)
  - Deadlock handling

- [x] **test_runner.zig**
  - Add test utilities and helpers (ref: pg.zig/src/t.zig)
  - Implement test database setup/teardown (ref: zqlite/src/pool.zig:161-176)
  - Add performance measurement

## Priority 6: API Documentation

### Overview
Add comprehensive inline documentation for all public APIs.

### Implementation Checklist

- [ ] **All public functions in src/**
  - Add doc comments with description
  - Document parameters and return values
  - Include usage examples
  - Document error conditions

- [ ] **README.md**
  - Expand with API reference section
  - Add troubleshooting guide
  - Include performance tips
  - Add migration guide from other databases

- [ ] **examples/**
  - Add advanced examples (transactions, pooling, prepared statements)
  - Create performance optimization examples
  - Add error handling examples

## Priority 7: Additional Features

### Overview
Add features that exist in mature libraries but are missing in zkuzu.

### Reference Implementation
- **pg.zig/src/metrics.zig:5-21** - Metrics structure and counters
- **pg.zig/src/metrics.zig:32-56** - Metric collection functions
- **pg.zig/src/pool.zig:200-260** - Reconnector with health checks
- **zqlite/src/pool.zig:119-122** - Connection callbacks pattern

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
**Timeline: 2-3 weeks**
- Focus on memory management, error handling, and state management
- These form the foundation for other improvements
- Must be done before other changes to avoid rework

### Phase 2: Type Safety and Testing (Priorities 4-5)
**Timeline: 2 weeks**
- Build on the solid foundation from Phase 1
- Improve developer experience and reliability
- Ensure no regressions with comprehensive tests

### Phase 3: Documentation and Polish (Priorities 6-7)
**Timeline: 1-2 weeks**
- Document all improvements
- Add nice-to-have features
- Prepare for wider adoption

### Phase 4: Advanced Features (Priority 8)
**Timeline: Ongoing**
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
