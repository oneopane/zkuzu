# zkuzu - Zig Wrapper for Kuzu Graph Database

A Zig wrapper for [Kuzu](https://kuzudb.com/), an embedded graph database, similar in design to the zqlite SQLite wrapper.

## Features

- Idiomatic Zig API for Kuzu
- Exec vs Query ergonomics (`conn.exec` for DDL/DML, `conn.query` for rows)
- Prepared statements with typed parameter binding
- Typed row getters (scalars, strings/blobs, temporals, uuid, decimal string, internal_id)
- Basic transactions (begin/commit/rollback)
- Name-based column access with O(1) lookup
- Connection pooling
- Examples and tests

## Setup Instructions

### 1. Choose a Kuzu Provider (no manual copies needed)

By default, builds use a prebuilt Kuzu binary fetched via `build.zig.zon` (pinned to v0.11.2), and link to it dynamically. You can switch providers:

- Prebuilt (default): fetch platform archive from GitHub releases.
- System: link against a system-installed Kuzu (provide include/lib dirs).
- Local: use files in `lib/` (static or shared).
- Source: build Kuzu from source via CMake, using Zig's toolchain.

Examples:

```bash
# Prebuilt (default) — fetches per-OS archive on demand
zig build example-basic -Dkuzu-provider=prebuilt

# System — you supply include/lib dirs
zig build example-basic -Dkuzu-provider=system \
  -Dkuzu-include-dir=/usr/local/include \
  -Dkuzu-lib-dir=/usr/local/lib

# Local — use lib/ folder (supports static or shared)
zig build example-basic -Dkuzu-provider=local

# Source — builds Kuzu from source with CMake using zig cc/c++
zig build example-basic -Dkuzu-provider=source
  # Requires CMake installed; builds in zig-cache/kuzu-src-build
```

When running installed binaries directly (outside `zig build` execution), you may need to set the dynamic library search path for shared Kuzu builds:

- macOS: export DYLD_LIBRARY_PATH=/path/to/kuzu/lib:$DYLD_LIBRARY_PATH
- Linux: export LD_LIBRARY_PATH=/path/to/kuzu/lib:$LD_LIBRARY_PATH
- Windows: ensure the directory with the Kuzu DLL is on PATH

For macOS (universal) / Linux (x86_64/aarch64) / Windows (x86_64), prebuilt URLs and hashes are pinned in `build.zig.zon`. The build downloads only when first used and then caches the archive.

Manual (Local provider): If you prefer to vendor files yourself, place either the shared library or the static library in `lib/` and build with `-Dkuzu-provider=local`:

```bash
# Shared (from release asset):
#   macOS:  cp libkuzu.dylib lib/
#   Linux:  cp libkuzu.so lib/
# Static (from source build):
#   cp /path/to/kuzu/build/src/libkuzu.a lib/
```

The header file (`kuzu.h`) is provided by the provider (prebuilt/system/source). For the local provider, ensure `lib/kuzu.h` is present.

### 2. Build and Test

```bash
# Run tests
zig build test

# Run examples
zig build example-basic
zig build example-prepared
```

Optional slow tests (timeouts/interrupt behavior):

```bash
# Enable slow/unstable tests (may take ~10s) 
zig build test -Dslow-tests=true
```

## Quickstart: Exec vs Query

```zig
const std = @import("std");
const zkuzu = @import("zkuzu");

pub fn main() !void {
    var db = try zkuzu.open("zig-cache/zkuzu-quickstart/db", null);
    defer db.deinit();

    var conn = try db.connection();
    defer conn.deinit();

    // DDL/DML
    try conn.exec("CREATE NODE TABLE IF NOT EXISTS Person(name STRING, age INT64, PRIMARY KEY(name))");
    try conn.exec("MERGE (:Person {name:'Alice', age:30})");

    // Query rows
    var qr = try conn.query("MATCH (p:Person) RETURN p.name AS name, p.age AS age");
    defer qr.deinit();
    while (try qr.next()) |row_val| {
        const row = row_val; defer row.deinit();
        const name = try row.getStringByName("name");
        const age = try row.getIntByName("age");
        std.debug.print("{s} ({d})\n", .{name, age});
    }
}
```

## API Overview

### Database Operations
- `zkuzu.open(path, config)` - Open or create a database
- `Database.connection()` - Create a new connection
- `Database.deinit()` - Close the database

### Connection Operations
- `Conn.query(cypher)` - Execute a Cypher query (returns rows or summary)
- `Conn.exec(cypher)` - Execute statements without rows (DDL/DML)
- `Conn.prepare(cypher)` - Prepare a statement for reuse
- `Conn.beginTransaction()` - Start a transaction
- `Conn.commit()` - Commit transaction
- `Conn.rollback()` - Rollback transaction
- `Conn.lastErrorMessage()` - Fetch the latest Kuzu error string (owned by the connection; cleared on success)
 - `Conn.setTimeout(ms)` / `Conn.setMaxThreads(n)` - Performance knobs
 - `Conn.interrupt()` - Best-effort cancel of a running query

### Prepared Statements
- `PreparedStatement.bindBool(name, value)`
- `PreparedStatement.bindInt(name, i64)` / `bindInt32` / `bindInt16` / `bindInt8`
- `PreparedStatement.bindFloat(name, f64)`
- `PreparedStatement.bindString(name, value)`
- `PreparedStatement.bindUInt64` / `bindUInt32` / `bindUInt16` / `bindUInt8`
- `PreparedStatement.bindDate(name, kuzu_date_t)`
- `PreparedStatement.bindTimestamp(name, kuzu_timestamp_t)`
- `PreparedStatement.bindTimestampNs/Ms/Sec/Tz(...)`
- `PreparedStatement.bindInterval(name, kuzu_interval_t)`
- `PreparedStatement.bindNull(name, kuzu_data_type_id)`
- `PreparedStatement.execute()`

### Result Handling
- `QueryResult.next()` - Returns the next row handle (`?*Row`); always `defer row.deinit()` before iterating again
- `Row.getBool(index)` / `Row.getInt(index)` / `Row.getFloat(index)`
- `Row.getUInt(index)`
- `Row.getString(index)` - Borrowed `[]const u8` until `row.deinit()`
- `Row.copyString(alloc, index)` - Owned copy
- `Row.getBlob(index)` / `Row.copyBlob(alloc, index)`
- `Row.getDate(index)` / `Row.getTimestamp(index)` / `Row.getInterval(index)`
- `Row.getUuid(index)` / `Row.copyUuid(alloc, index)`
- `Row.getDecimalString(index)` / `Row.copyDecimalString(alloc, index)`
- `Row.getInternalId(index)`
- Composite accessors:
  - `Value.getListLength()` / `getListElement(idx)` for LIST/ARRAY values
  - `Value.getStructFieldCount()` / `getStructFieldName(idx)` / `getStructFieldValue(idx)` for STRUCT/NODE/REL values
  - `Value.getMapSize()` / `getMapKey(idx)` / `getMapValue(idx)` for MAP values
  - Recursive rel helpers: `Value.asRecursiveRel().nodeList()` / `.relList()`
- Graph object helpers:
  - `Value.asNode()` → `Node` view with `idValue()`, `labelValue()`, `propertyCount()`, `propertyName(idx)`, `propertyValue(idx)`
  - `Value.asRel()` → `Rel` view with `idValue()`, `srcIdValue()`, `dstIdValue()`, `labelValue()`, `property*` accessors
- Struct/graph field names can be copied via `Value.copyStructFieldName(alloc, idx)` and `Node.copyPropertyName(alloc, idx)` if you need owned buffers.
- Name-based access: `Row.getIntByName("age")`, `Row.getStringByName("name")`

Notes on lifetimes:
- Strings/blobs returned from `Row.getString/getBlob` are borrowed from Kuzu and valid until `row.deinit()` or the next `next()` call. Use `copyString/copyBlob` to own the data.
- `Row.deinit()` frees the underlying `kuzu_flat_tuple` and any returned C buffers created during getters.
- Each row handle is exclusive; drop it with `row.deinit()` before requesting another row to avoid leaking tuples.

### Error Handling
- `Conn.lastErrorMessage()` reflects the most recent failure and returns `null` after the next successful call. Freeing is handled automatically when the connection clears or overwrites the message.

```zig
const invalid_result = blk: {
    const res = conn.query("RETURN 1 +") catch |err| switch (err) {
        zkuzu.Error.QueryFailed => {
            if (conn.lastErrorMessage()) |msg| {
                std.debug.print("Query failed: {s}\n", .{msg});
            } else {
                std.debug.print("Query failed without message\n", .{});
            }
            break :blk null;
        },
        else => return err,
    };
    break :blk res;
};
if (invalid_result) |qr_bad| {
    defer qr_bad.deinit();
    std.debug.print("Unexpected success for invalid query\n", .{});
}
```

Implemented ergonomics:
- Generic getter `row.get(T, idx|name)` with copy variants for slice-like types.

### Connection Pooling
```zig
var pool = try zkuzu.Pool.init(allocator, &db, max_connections);
defer pool.deinit();

// Execute query with pooled connection
var result = try pool.query("MATCH (n) RETURN n");
```

Planned ergonomics:
- Optional `ConnHandle` that auto-releases to the pool on `defer` to reduce misuse.
- Acquire timeout/backpressure configuration.

Thread-safety:
- Prefer one connection per thread. The pool pattern is safe across threads when each checked-out connection is used by a single thread at a time.

## API Reference

This high-level reference mirrors inline doc comments. See the source for full details and examples.

- Database
  - `zkuzu.open(path, config) !Database` – open/create database
  - `Database.connection() !Conn` – create connection
  - `Database.deinit()` – close DB
- Connection
  - `Conn.query(sql) !QueryResult` – execute and get rows
  - `Conn.exec(sql) !void` – execute, discard rows
  - `Conn.prepare(sql) !PreparedStatement` – prepare for reuse
  - `Conn.beginTransaction()/commit()/rollback()` – manual transactions
  - `Conn.setTimeout(ms) !void`, `Conn.setMaxThreads(n) !void`, `Conn.getMaxThreads() !u64`
  - `Conn.interrupt() void`, `Conn.validate() !void`, `Conn.healthCheck() !void`
  - `Conn.lastErrorMessage() ?[]const u8`, `Conn.lastError() ?*const KuzuError`
- PreparedStatement
  - `bind{Bool,Int,Int32,Int16,Int8,UInt64,UInt32,UInt16,UInt8,Float,String,Date,Timestamp,TimestampNs,TimestampMs,TimestampSec,TimestampTz,Interval,Null}(...)
  - `execute() !QueryResult`, `deinit()`
- QueryResult
  - `next() !?*Row`, `reset()`, `isSuccess() bool`, `getErrorMessage() !?[]u8`
  - `getColumnCount() u64`, `getColumnName(idx) ![]const u8`, `getColumnIndex(name) !?u64`, `getColumnDataType(idx) !ValueType`
  - `getSummary() !QuerySummary`
- Row
  - `get(T, idx|name) !T` – generic typed getter with null handling
  - Convenience: `getBool/getInt/getUInt/getFloat/getDouble/getString/getBlob/getDate/getTimestamp/getTimestampTz/getInterval/getUuid/getDecimalString/getInternalId`
  - Copy helpers: `copyString/copyBlob/copyUuid/copyDecimalString`
  - `isNull(idx) !bool`
- Value
  - Type conversion: `toBool/toInt/toUInt/toFloat/toString/toBlob/toDate/toTimestamp/toTimestampTz/toInterval/toUuid/toDecimalString/toInternalId`
  - Collections: `getListLength()/getListElement(i)`; struct: `getStructFieldCount()/getStructFieldName(i)/getStructFieldValue(i)`; map: `getMapSize()/getMapKey(i)/getMapValue(i)`
  - Graph wrappers: `asNode()/asRel()/asRecursiveRel()` with property helpers
- Pool
  - `Pool.init(allocator, &db, max) !Pool`, `deinit()`
  - `acquire() !Conn`, `release(Conn)`
  - `withConnection(T, ctx, func) T`, `withTransaction(T, ctx, func) T`
  - `query(sql) !QueryResult`, `getStats() PoolStats`, `cleanupIdle(seconds) !void`, `healthCheckAll() !void`

## Type Mapping

- Scalars
  - Bool → `bool`
  - Int8/16/32/64 → `i8/i16/i32/i64` (use `Row.get(T, ...)` for narrower types; bounds checked)
  - UInt8/16/32/64 → `u8/u16/u32/u64` (bounds checked; negative to unsigned is a conversion error)
  - Float/Double → `f32/f64` via `Row.get(f32|f64, ...)` or `Row.getFloat()/getDouble()`
- Strings/Blobs
  - String → `[]const u8` (borrowed); copy with `row.copyString(alloc, idx)`
  - Blob → `[]const u8` (borrowed); copy with `row.copyBlob(alloc, idx)`
- Temporals
  - Date → `c.kuzu_date_t`
  - Timestamp (µs) → `c.kuzu_timestamp_t` (also supports `TimestampNs/Ms/Sec` via conversion)
  - TimestampTz → `c.kuzu_timestamp_tz_t`
  - Interval → `c.kuzu_interval_t`
- Other primitives
  - Uuid → string form `[]const u8` via `getUuid()/toUuid()`
  - Decimal → string form `[]const u8` via `getDecimalString()/toDecimalString()`
  - InternalId → `c.kuzu_internal_id_t`
- Composite
  - List/Array → `[]T` via `Row.get([]T, ...)` (recursive)
  - Map → `[]struct { key: K, value: V }`
  - Struct/Union → matching Zig struct with identical field names
  - Graph types → `Value.asNode()/asRel()/asRecursiveRel()` with helpers for labels/properties

## Troubleshooting

- Dynamic library not found at runtime
  - macOS: set `DYLD_LIBRARY_PATH` to Kuzu `lib/` directory
  - Linux: set `LD_LIBRARY_PATH`
  - Windows: add directory containing the Kuzu DLL to `PATH`
- error.QueryFailed but no message
  - Check `QueryResult.getErrorMessage()` when available or `Conn.lastErrorMessage()` after failure
  - Ensure you didn’t `deinit()` the result before reading the message
- error.TypeMismatch from getters
  - Use `Row.get(T, idx|name)` with correct `T` or the dedicated typed getter
  - For nullable columns, make `T` optional (e.g., `?i64`)
- Transaction state errors
  - `beginTransaction()` only valid when idle; `commit/rollback()` only when in a transaction
  - Prefer `Pool.withTransaction` or the safety pattern with `need_rollback`
- error.Busy from overlapping usage
  - The connection forbids overlapping operations while a `QueryResult` is alive.
  - Always `qr.deinit()` before issuing another `query/prepare/execute/beginTransaction` on the same connection.
  - `exec()` is safe because it immediately deinitializes the internal result.
- Interrupted or timeout
  - Use `Conn.setTimeout(ms)` before running a query; call `Conn.interrupt()` from another thread to cancel

## Performance Tips

- Reuse prepared statements for repeated queries to reduce parse/bind overhead
- Prefer borrowed slices (`getString/getBlob`) and only copy when needed
- Batch writes inside a transaction to avoid per-statement commits
- Tune threads: `setMaxThreads(0)` lets Kuzu pick; otherwise set explicitly
- Use the pool for concurrent workloads; size according to CPU/IO
- Avoid name lookups inside tight loops by caching indices (`getColumnIndex`) once
- Use `validate()`/`healthCheck()` for long-lived connections to preempt failures

## Migration Guide

- From zqlite (SQLite):
  - `conn.exec` vs `conn.query` parallels zqlite; SQL → Cypher
  - Prepared statements: `bind*` and `execute()` are analogous; named params use `$name`
  - Result scanning: `Row.get(T, idx|name)` replaces column-numbered `getX`
  - Transactions: manual begin/commit/rollback or use `Pool.withTransaction`
- From Neo4j drivers:
  - Cypher syntax is familiar; Kuzu is embedded, so you manage lifecycles (DB/Conn)
  - Node/Rel values are accessed via `Value.asNode()/asRel()` helpers
  - No network layer; pooling is for concurrent local handles
- From other embedded stores:
  - Memory ownership follows Zig patterns; free `QueryResult` and row handles promptly
  - Borrowed vs owned data is explicit; copy when values outlive their owners

## Project Structure

```
zkuzu/
├── build.zig          # Build configuration
├── build.zig.zon      # Package manifest
├── src/
│   ├── root.zig       # Main module exports
│   ├── conn.zig       # Connection and query handling
│   └── pool.zig       # Connection pooling
├── lib/               # Optional: only used with local provider
│   ├── kuzu.h         # Kuzu C API header (for local provider)
│   └── libkuzu.*      # Kuzu static/shared library (for local provider)
├── examples/
│   ├── basic.zig      # Exec vs query, scanning rows
│   └── prepared.zig   # Typed binds/getters, temporals
├── test_runner.zig    # Test runner
└── README.md          # This file
```

## Notes

- Prebuilt and system providers link to a shared Kuzu library. The source provider builds Kuzu with CMake using zig cc/c++ and links the resulting shared library. The local provider can use either static or shared libraries that you place in `lib/`.
- The wrapper follows similar patterns to zqlite for consistency.
- Lifetimes: string/blob slices returned from rows are borrowed. Process them before the next `next()` or copy via `copyString/copyBlob`.
- Platform-specific linking is handled in build.zig.
- Tests create temporary databases in `zig-cache/`.

## Transactions

Current API:
- Manual control via `beginTransaction()`, `commit()`, `rollback()`.

Safety tip:
```zig
try conn.beginTransaction();
var need_rollback = true;
defer if (need_rollback) conn.rollback() catch {};

try conn.exec("...");
try conn.exec("...");

try conn.commit();
need_rollback = false;
```

Planned ergonomics:
- `conn.begin() -> Tx` handle with `commit()/rollback()` and `rollbackOnClose()` pattern.
Implemented:
- `pool.withTransaction(fn)` helper to scope transactions with automatic rollback-on-error.

Threading:
- Use one connection per thread. Avoid sharing a single `Conn` across threads without external synchronization.

### Pool Transactions

`Pool.withTransaction` wraps `BEGIN/COMMIT/ROLLBACK` around a pooled connection and guarantees release back to the pool. It auto-commits when the callback returns successfully and the transaction is still active; otherwise it rolls back.

```zig
const std = @import("std");
const zkuzu = @import("zkuzu");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var db = try zkuzu.open("zig-cache/zkuzu-pool-tx-readme/db", null);
    defer db.deinit();

    var pool = try zkuzu.Pool.init(alloc, &db, 4);
    defer pool.deinit();

    // Create table once
    var _q = try pool.query("CREATE NODE TABLE IF NOT EXISTS Item(id INT64, PRIMARY KEY(id))");
    _q.deinit();

    // Commit path: returns success -> auto-commit
    const TxResult = zkuzu.Error || error{PoolExhausted};
    _ = try pool.withTransaction(TxResult!void, .{}, struct {
        fn run(tx: *zkuzu.Pool.Transaction, _: @TypeOf(.{})) TxResult!void {
            try tx.exec("MERGE (:Item {id: 1})");
            // no explicit commit needed; auto-commit on success
            return;
        }
    }.run);

    // Rollback path: return an error -> auto-rollback
    const TxResult2 = zkuzu.Error || error{PoolExhausted, Intentional};
    const r2 = pool.withTransaction(TxResult2!void, .{}, struct {
        fn run(tx: *zkuzu.Pool.Transaction, _: @TypeOf(.{})) TxResult2!void {
            try tx.exec("MERGE (:Item {id: 999})");
            return error.Intentional; // triggers rollback
        }
    }.run);
    if (r2) |_| unreachable else |_| {}

    // Verify effects
    var qr1 = try pool.query("MATCH (n:Item {id: 1}) RETURN n.id");
    defer qr1.deinit();
    _ = try qr1.next() orelse @panic("expected committed row");

    var qr2 = try pool.query("MATCH (n:Item {id: 999}) RETURN n.id");
    defer qr2.deinit();
    if (try qr2.next()) |_| @panic("row should have been rolled back");
}
```

Rules of thumb:
- Do not keep references to `tx` or inner statements beyond the callback.
- You can explicitly `tx.commit()` or `tx.rollback()`; `withTransaction` detects that and won’t double-commit.
- If `withTransaction` returns an error, the transaction is rolled back and the connection is released.

## Error Handling

Current:
- Functions return Zig errors mapped from Kuzu states; error messages are accessible on `QueryResult` where available.
- Prepared statement binds and execute now capture Kuzu's detailed binder messages automatically; call `Conn.lastErrorMessage()` after failures for specifics. Connection setters (`setTimeout`, `setMaxThreads`) also populate the last error with descriptive fallbacks.

Planned polish:
- Map Kuzu errors to a richer Zig error set and propagate the message alongside (e.g., `error.QueryFailed` with message).
- Add `conn.lastMessage()` or return message directly from `query/prepare` on error.

## Multi-statement Results

Planned:
- Support batches like `RUN ...; RUN ...` via `qr.hasNextQueryResult()` and `qr.getNextQueryResult()` to iterate statement results.

## Type Coverage and Binds

Implemented:
- Scalars: bool, int64, uint64, float64, plus narrower int/uint bind helpers.
- Strings/blobs with borrowed and copy variants.
- Temporals: date, timestamp (ns/ms/sec/tz), interval.
- UUID, decimal-as-string, internal_id.

Planned:
- Complex types: lists/arrays, struct/map/union with recursive getters and typed bind helpers.
- Node/Relationship wrappers exposing labels/properties.
- Decimal bind helpers by string with precision/scale (logical type crafting).
- Friendly timestamp helpers to/from Zig time types.

## Arrow Interface

Planned:
- Light wrapper over `get_arrow_schema()/get_next_arrow_chunk()` with correct release semantics, plus an example.

## Examples

- `examples/basic.zig`: schema, DDL/DML via `exec`, row scanning, summaries.
- `examples/prepared.zig`: prepared statements, typed binds/getters, temporals.
- `examples/transactions.zig`: manual transaction pattern with safe rollback.
- `examples/pool.zig`: pool usage, `withConnection` and `withTransaction`.
- `examples/performance.zig`: prepared reuse, tuning, borrow vs copy.
- `examples/error_handling.zig`: capturing errors from `Conn` and binds.

Build targets:
- `zig build example-basic`
- `zig build example-prepared`
- `zig build example-transactions`
- `zig build example-pool`
- `zig build example-performance`
- `zig build example-errors`

## Testing and CI

- Run tests: `zig build test`.
- Add tests for typed binds/getters (including complex types when implemented), null round-trips, mismatches (TypeMismatch), and multi-statement results.
- Consider leak detection around hot paths using `GPA.detectLeaks = true` and assertions that all C-returned strings/blobs are destroyed.
- CI matrix for macOS/Linux; ensure the linked static library set matches each platform.

## Build and Packaging

- The build wires example targets and tests; see `build.zig` for platform-specific linking.
- Ensure Kuzu version compatibility and that required `.a` files exist. A small script can verify presence of all static libs prior to build.

## Contributing

Before opening a PR, please see `AGENTS.md` for repository guidelines.

- Dev quickstart
  - Run tests: `zig build test`
  - Run examples: `zig build example-basic` (also: prepared/transactions/pool/performance/errors)
  - Choose provider: `-Dkuzu-provider=prebuilt|local|system|source`
- Style: run `zig fmt .`; 4-space indentation; keep modules small and cohesive.
- Commits: use Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`).
- PR checklist: description, linked issues, reproduction commands, expected output, OS and provider used. Attach logs if behavior differs across OS.

## License

This wrapper follows the same license as your zqlite wrapper. Kuzu itself is licensed under the MIT License.
