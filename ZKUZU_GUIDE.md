# ZKUZU Guide

A practical, self‑contained guide to using zkuzu — a Zig wrapper around the Kuzu embedded graph database. This document covers setup, building, the full public API, usage patterns, lifetimes, transactions, pooling, and troubleshooting so you don’t need to read the source.

## At a Glance

- Import: `const zkuzu = @import("zkuzu");`
- Open DB: `var db = try zkuzu.open("path/to/db", null);` (or pass a `SystemConfig`)
- Connect: `var conn = try db.connection();`
- Exec (no rows): `try conn.exec("CREATE NODE TABLE ...");`
- Query (rows): iterate `QueryResult` and `Row` then `deinit()`
- Prepare + bind: `var ps = try conn.prepare("... $name ..."); try ps.bindString("name", "Alice");`
- Transactions: `beginTransaction()`, `commit()`, `rollback()` (or use `Pool.withTransaction`)
- Pooling: `var pool = try zkuzu.Pool.init(alloc, &db, 4);`
- Errors: catch `zkuzu.Error.*`; inspect `conn.lastErrorMessage()` or `conn.lastError()`

---

## Install, Build, Test

The build supports multiple Kuzu providers. By default it fetches a prebuilt Kuzu binary.

- Prebuilt (default):
  - `zig build test`
  - `zig build example-basic` (also: `example-prepared`, `example-transactions`, `example-pool`, `example-performance`, `example-errors`)

- Local (vendored headers/libs in `lib/`):
  - `zig build -Dkuzu-provider=local test`

- System install:
  - `zig build -Dkuzu-provider=system -Dkuzu-include-dir=/path/include -Dkuzu-lib-dir=/path/lib test`

- Build from source (requires CMake):
  - `zig build -Dkuzu-provider=source test`

When running binaries manually with a shared Kuzu lib, set the dynamic library search path:
- macOS: `export DYLD_LIBRARY_PATH=lib:$DYLD_LIBRARY_PATH`
- Linux: `export LD_LIBRARY_PATH=lib:$LD_LIBRARY_PATH`
- Windows: ensure the directory with the Kuzu DLL is on `PATH`

Formatting: `zig fmt .`

---

## Quickstart

```zig
const std = @import("std");
const zkuzu = @import("zkuzu");

pub fn main() !void {
    // Open or create the database. String literals work directly; for dynamic
    // paths use zkuzu.toCString(alloc, path).
    var db = try zkuzu.open("zig-cache/zkuzu-quickstart/db", null);
    defer db.deinit();

    var conn = try db.connection();
    defer conn.deinit();

    // DDL/DML without rows
    try conn.exec("CREATE NODE TABLE IF NOT EXISTS Person(name STRING, age INT64, PRIMARY KEY(name))");
    try conn.exec("MERGE (:Person {name:'Alice', age:30})");

    // Query rows (always deinit row handles and result when finished)
    var qr = try conn.query("MATCH (p:Person) RETURN p.name AS name, p.age AS age");
    defer qr.deinit();

    while (try qr.next()) |row| : (row.deinit()) {
        const name = try row.getByName([]const u8, "name");
        const age = try row.getByName(i64, "age");
        std.debug.print("{s} ({d})\n", .{ name, age });
    }
}
```

---

## Module Export Map

- `zkuzu.Database`, `zkuzu.SystemConfig`
- `zkuzu.Conn`, `zkuzu.ConnStats` (see `Conn.getStats()`)
- `zkuzu.PreparedStatement`
- `zkuzu.QueryResult`, `zkuzu.Row`, `zkuzu.Rows`
- `zkuzu.Value`, `zkuzu.ValueType`, `zkuzu.QuerySummary`
- `zkuzu.Pool`, `zkuzu.Transaction`
- `zkuzu.Error` (error set), `zkuzu.checkState` (Kuzu state helper)
- `zkuzu.toCString` (utility)
- `zkuzu.c` (Kuzu C API types; e.g., `zkuzu.c.kuzu_timestamp_t`)

---

## Database

- Open or create:
  - `zkuzu.open(path: [*:0]const u8, config: ?SystemConfig) !Database`
  - `Database.init(path, config) !Database` (same semantics)
- Close: `Database.deinit()`
- New connection: `Database.connection() !Conn`

System configuration:
```zig
const cfg = zkuzu.SystemConfig{
    .buffer_pool_size = 1 << 30,
    .max_num_threads = 0, // 0 lets Kuzu decide
    .enable_compression = true,
    .read_only = false,
    .max_db_size = 1 << 43,
    .auto_checkpoint = true,
    .checkpoint_threshold = 1 << 26,
};
var db = try zkuzu.open("/path/db", cfg);
```

Tips
- String literals are fine for `path`. For dynamic strings, use `zkuzu.toCString(alloc, path)`.
- Each connection is intended for use by a single thread at a time.

---

## Connections (Conn)

Core operations
- `query(cypher: []const u8) !QueryResult` – execute and iterate rows
- `exec(cypher: []const u8) !void` – execute and discard rows (DDL/DML convenience)
- `prepare(cypher: []const u8) !PreparedStatement` – compile for repeated use

Transactions
- `beginTransaction() !void`
- `commit() !void`
- `rollback() !void`

Tuning and control
- `setTimeout(ms: u64) !void`
- `setMaxThreads(n: u64) !void` / `getMaxThreads() !u64`
- `interrupt() void` – best‑effort cancel
- `validate() !void` – verify and recover a failed handle
- `healthCheck() !void` – lightweight liveness check
- `getStats() ConnStats` – snapshot of counters/timestamps

Errors
- On failure, operations return `zkuzu.Error.*`. After failures:
  - `conn.lastErrorMessage() ?[]const u8` – latest message (owned by connection; cleared on success)
  - `conn.lastError() ?*const zkuzu.KuzuError` – structured error with `.op` and `.category`

Important rules
- No overlapping operations on a single connection: while a `QueryResult` is alive, `prepare/execute/query/beginTransaction` return `error.Busy`. `QueryResult.deinit()` clears the guard.
- After a failure, the connection marks itself “failed”; `query/prepare/execute/validate` attempt recovery.

Example
```zig
var qr = try conn.query("MATCH (p) RETURN p.name AS name");
while (try qr.next()) |row| : (row.deinit()) {
    const name = try row.getByName([]const u8, "name");
}
qr.deinit(); // must be closed before using conn again for overlapping ops
```

Stats fields (via `ConnStats`)
- `created_ts`, `last_used_ts`, `last_error_ts`, `last_reset_ts`
- Counters: `total_queries`, `total_executes`, `total_prepares`,
  `tx_begun`, `tx_committed`, `tx_rolled_back`, `failed_operations`,
  `reconnects`, `validations`, `pings`

---

## Prepared Statements

Workflow
1) `var ps = try conn.prepare("MATCH (p) WHERE p.age > $min RETURN p");`
2) Bind parameters by name (without `$`)
3) `var qr = try ps.execute();` then iterate rows; `qr.deinit()`; `ps.deinit()`

Bind helpers
- Booleans/ints/uints: `bindBool`, `bindInt`, `bindInt32`, `bindInt16`, `bindInt8`, `bindUInt64`, `bindUInt32`, `bindUInt16`, `bindUInt8`
- Floating point: `bindFloat` (f64)
- Strings: `bindString`
- Temporals: `bindDate`, `bindTimestamp`, `bindTimestampNs`, `bindTimestampMs`, `bindTimestampSec`, `bindTimestampTz`
- Intervals: `bindInterval`
- Nulls: `bindNull(name, value_type)` where `value_type` is a Kuzu logical type id
  - Example: `try ps.bindNull("age", @intFromEnum(zkuzu.ValueType.Int64));`

Errors
- Bind failures return `error.BindFailed` and set `conn.lastErrorMessage()`.
- `execute()` failures return `error.ExecuteFailed` and set `conn.lastError()/lastErrorMessage()`.

Example
```zig
var ps = try conn.prepare("MATCH (p:Person) WHERE p.age > $min RETURN p.name AS name, p.age AS age");
defer ps.deinit();
try ps.bindInt("min", 30);
var qr = try ps.execute();
while (try qr.next()) |row| : (row.deinit()) {
    const name = try row.getByName([]const u8, "name");
    const age = try row.getByName(i64, "age");
}
qr.deinit();
```

---

## Query Results and Rows

QueryResult
- Lifetime: call `qr.deinit()` when done (frees arena, notifies connection)
- Metadata: `getColumnCount()`, `getColumnName(idx)`, `getColumnIndex(name)`, `getColumnDataType(idx) -> ValueType`
- Iteration: `while (try qr.next()) |row| { defer row.deinit(); ... }`
- Reset iterator: `qr.reset()`
- Summary: `qr.getSummary() -> QuerySummary{ compiling_time_ms, execution_time_ms }`
- Error text (on failure): `qr.getErrorMessage() !?[]u8` (owned copy)

Row
- Generic getter: `row.get(T, idx)` and `row.getByName(T, name)`
  - Scalars: `bool`, `i8/i16/i32/i64`, `u8/u16/u32/u64`, `f32/f64`, `[]const u8`
  - Nullables: use `?T` (e.g., `?i64`). Non‑optional `T` on NULL → `error.InvalidArgument`.
  - Lists/arrays: `[]T` (e.g., `[]const i64`) with recursive conversion.
  - Struct/Union: to a Zig struct with matching field names.
  - Map: `[]struct{ key: K, value: V }` via `Value` navigation (see below).
  - Graph: request `zkuzu.Value` and use `.asNode()/.asRel()` wrappers.
- Convenience: `getBool/getInt/getUInt/getFloat/getDouble/getString/getBlob/getDate/getTimestamp/getTimestampTz/getInterval/getUuid/getDecimalString/getInternalId`
- Copy helpers: `copyString(alloc, idx) !?[]u8`, `copyBlob(alloc, idx) !?[]u8`, `copyUuid`, `copyDecimalString`
- Null checks: `isNull(idx) !bool`

Borrowed vs owned
- `getString/getBlob` return borrowed slices valid until `row.deinit()` (or `qr.deinit()`). Copy if the data must outlive the row.
- `row.copyString/copyBlob` return owned memory to free with the allocator you passed.

Examples
```zig
// Named access with O(1) column cache
try conn.exec("CREATE NODE TABLE IF NOT EXISTS Person(name STRING, age INT64, PRIMARY KEY(name))");
try conn.exec("MERGE (:Person {name:'Bob', age:25})");
var qr = try conn.query("MATCH (p:Person) RETURN p.name AS name, p.age AS age");
while (try qr.next()) |row| : (row.deinit()) {
    const name = try row.getByName([]const u8, "name");
    const age = try row.getByName(i64, "age");
}
qr.deinit();
```

---

## Value API (advanced)

Use `row.get(zkuzu.Value, idx)` to receive a `Value` for detailed, type‑driven navigation. All `Value` getters validate logical types and return errors on mismatches.

Conversion
- `toBool()`, `toInt() -> i64`, `toUInt() -> u64`, `toFloat() -> f64`
- `toString() -> []const u8`, `toBlob() -> []const u8`
- `toDate() -> c.kuzu_date_t`, `toTimestamp() -> c.kuzu_timestamp_t`, `toTimestampTz()`, `toInterval()`
- `toUuid() -> []const u8`, `toDecimalString() -> []const u8`, `toInternalId() -> c.kuzu_internal_id_t`
- `getType() -> ValueType`, `isNull() -> bool`

Collections
- Lists/Arrays: `getListLength()`, `getListElement(i) -> Value`
- Struct/Union/Node/Rel fields: `getStructFieldCount()`, `getStructFieldName(i)`, `getStructFieldValue(i)`
- Maps: `getMapSize()`, `getMapKey(i) -> Value`, `getMapValue(i) -> Value`

Graph helpers
- `asNode()/.asRel()/.asRecursiveRel()` → wrappers with:
  - Node: `idValue()`, `labelValue()`, `propertyCount()`, `propertyName(i)`, `propertyValue(i)`
  - Rel: `idValue()`, `srcIdValue()`, `dstIdValue()`, `labelValue()`, `propertyCount()`, `propertyName(i)`, `propertyValue(i)`
  - RecursiveRel: `nodeList()`, `relList()`

Ownership
- `Value` returned from `Row.get(zkuzu.Value, ...)` is owned; call `value.deinit()` when done.
- Borrowed strings returned by `Value` are tied to the row/result arena unless you copy them.

---

## Transactions

Manual
```zig
try conn.beginTransaction();
var need_rollback = true;
defer if (need_rollback) conn.rollback() catch {};

try conn.exec("...");
try conn.exec("...");

try conn.commit();
need_rollback = false;
```

With Pool helper
```zig
const R = zkuzu.Error || error{PoolExhausted};
_ = try pool.withTransaction(R!void, .{}, struct {
    fn run(tx: *zkuzu.Transaction, _: @TypeOf(.{})) R!void {
        try tx.exec("MERGE (:Item {id: 1})");
        return;
    }
}.run);
```

Notes
- `beginTransaction()` requires the connection to be idle (no active result).
- `commit()/rollback()` require an active transaction.

---

## Connection Pool

Setup
```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
var pool = try zkuzu.Pool.init(gpa.allocator(), &db, 4);
defer pool.deinit();
```

Usage
- Acquire/release: `const conn = try pool.acquire(); ... pool.release(conn);`
- Convenience query: `var qr = try pool.query("MATCH (n) RETURN n"); qr.deinit();`
- Scoped helpers:
  - `withConnection(T, ctx, func)` – runs `func(conn, ctx)` and releases
  - `withTransaction(T, ctx, func)` – wraps BEGIN/COMMIT/ROLLBACK; releases
- Maintenance: `getStats()`, `cleanupIdle(seconds)`, `healthCheckAll()`

Thread‑safety
- Safe to share a `Pool` across threads; each acquired `Conn` should be used by a single thread at a time.

---

## Errors & Diagnostics

Error set (non‑exhaustive)
- `DatabaseInit`, `ConnectionInit`, `InvalidDatabase`, `InvalidConnection`
- `Busy`, `QueryFailed`, `PrepareFailed`, `BindFailed`, `ExecuteFailed`
- `InvalidColumn`, `TypeMismatch`, `ConversionError`, `InvalidArgument`
- `TransactionFailed`, `TransactionAlreadyClosed`

Structured errors
- `conn.lastError() -> ?*const KuzuError` with fields:
  - `.op`: one of `{ connect, query, prepare, execute, bind, config, transaction }`
  - `.category`: coarse category `{ argument, constraint, transaction, connection, timeout, interrupt, memory, unknown }`
  - `.message`: owned message slice (lifetime managed by connection)

Typical pattern
```zig
_ = conn.query("RETURN 1 + ") catch |err| switch (err) {
    zkuzu.Error.QueryFailed => if (conn.lastErrorMessage()) |m| std.debug.print("Failed: {s}\n", .{m}),
    else => return err,
};
```

---

## Data Type Mapping

- Scalars
  - Bool → `bool`
  - Int8/16/32/64 → `i8/i16/i32/i64`
  - UInt8/16/32/64 → `u8/u16/u32/u64`
  - Float/Double → `f32/f64`
- Strings/Blobs
  - String → `[]const u8` (borrowed); copy via `row.copyString(alloc, idx)`
  - Blob → `[]const u8` (borrowed); copy via `row.copyBlob(alloc, idx)`
- Temporals
  - Date → `zkuzu.c.kuzu_date_t`
  - Timestamp (µs) → `zkuzu.c.kuzu_timestamp_t`
  - TimestampNs/Ms/Sec/Tz → respective `zkuzu.c` types
  - Interval → `zkuzu.c.kuzu_interval_t`
- Other
  - Uuid → string slice via `getUuid()/toUuid()`
  - Decimal → string slice via `getDecimalString()/toDecimalString()`
  - InternalId → `zkuzu.c.kuzu_internal_id_t`
- Composite
  - List/Array → `[]T`
  - Struct/Union → Zig struct with identical field names
  - Map → iterate key/value via `Value.getMapKey()/getMapValue()`
  - Graph → `Value.asNode()/asRel()/asRecursiveRel()` helpers

Conversion safety
- Narrowing conversions are checked; out‑of‑range → `error.ConversionError`.
- Type mismatches → `error.TypeMismatch`.
- NULL to non‑optional → `error.InvalidArgument`.

---

## Performance Tips

- Reuse prepared statements for repeated queries.
- Prefer borrowed slices; copy only when data must outlive the row.
- Batch writes inside a transaction.
- Tune `setMaxThreads(0)` (auto) or a fixed value; set `setTimeout(ms)` where appropriate.
- Use the pool for concurrent workloads; size by CPU/IO.
- Cache column indices with `qr.getColumnIndex(name)` for inner loops.

---

## Troubleshooting

- “Busy” errors
  - Always `qr.deinit()` before running another overlapping operation on the same connection.
- Dynamic library not found
  - Set `DYLD_LIBRARY_PATH` (macOS) or `LD_LIBRARY_PATH` (Linux) to your Kuzu `lib/`.
- No error message but failure
  - Check `qr.getErrorMessage()` (before `qr.deinit()`) or `conn.lastErrorMessage()`.
- Type errors
  - Ensure the requested Zig type matches the logical type (or use `?T` for nullable).
- Transaction errors
  - Only call `commit()/rollback()` when a transaction is active; prefer `Pool.withTransaction` for scoped safety.

---

## Project Structure (reference)

- `src/` – core Zig module (`root.zig`, `conn.zig`, `pool.zig`, etc.)
- `src/tests/` – tests (`zig build test` runs all)
- `examples/` – runnable samples (`zig build example-basic`, etc.)
- `lib/` – Kuzu headers and libs (used by `-Dkuzu-provider=local`)
- `build.zig`, `build.zig.zon` – build graph and pinned Kuzu deps

---

## FAQ

- How do I pass C temporal types?
  - Use `zkuzu.c.kuzu_timestamp_t{ .value = ... }` or construct via Kuzu helper functions in `zkuzu.c`.
- How do I bind NULL?
  - `ps.bindNull("name", @intFromEnum(zkuzu.ValueType.String));`
- Is `Conn` thread‑safe?
  - Each `Conn` has internal guards but is intended for single‑thread use. Use the pool for concurrency.
- Do I need to free strings from getters?
  - Borrowed slices from rows are freed when you `row.deinit()`/`qr.deinit()`. Copy variants return owned memory you must free.

---

## Example Targets

- `zig build example-basic`
- `zig build example-prepared`
- `zig build example-transactions`
- `zig build example-pool`
- `zig build example-performance`
- `zig build example-errors`

---

## Versioning & Compatibility

- Prebuilt provider URLs/hashes are pinned in `build.zig.zon`.
- If you vendor Kuzu (local provider), keep `kuzu.h` and `libkuzu.*` in `lib/` in sync with your target platform.

---

That’s it — you can use zkuzu end‑to‑end with the snippets and references above. For more patterns, the `examples/` folder mirrors this guide.

