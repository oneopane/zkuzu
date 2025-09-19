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

Planned ergonomics:
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
- Planned: types tour (lists/maps/structs/decimal/internal_id/uuid), Arrow export, and pool usage with parallel queries.

Build targets:
- `zig build example-basic`
- `zig build example-prepared`

## Testing and CI

- Run tests: `zig build test`.
- Add tests for typed binds/getters (including complex types when implemented), null round-trips, mismatches (TypeMismatch), and multi-statement results.
- Consider leak detection around hot paths using `GPA.detectLeaks = true` and assertions that all C-returned strings/blobs are destroyed.
- CI matrix for macOS/Linux; ensure the linked static library set matches each platform.

## Build and Packaging

- The build wires example targets and tests; see `build.zig` for platform-specific linking.
- Ensure Kuzu version compatibility and that required `.a` files exist. A small script can verify presence of all static libs prior to build.

## License

This wrapper follows the same license as your zqlite wrapper. Kuzu itself is licensed under the MIT License.
