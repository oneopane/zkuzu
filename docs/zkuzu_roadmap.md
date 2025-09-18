Here’s a focused code review of code/libs/zkuzu — what’s implemented, what’s missing, and how to strengthen tests.

  Current State

  - Provides basic wrappers: Database, Conn, QueryResult, PreparedStatement, Value, Row, Rows, and a simple Pool.
  - Supports opening DB, creating a connection, running queries, preparing statements, setting query timeout and max threads, and interrupting queries.
  - Includes a README, a Makefile, a custom test runner, and many prebuilt static libs under lib/ including kuzu.h.

  Build & Tests

  - Running zig build test on this repo fails: [1/1] zkuzu.test.basic database operations... FAIL: error.Unknown (only one test discovered).
  - The pool test in src/pool.zig is not being discovered/run by the test harness (only the test in src/zkuzu.zig shows up).
  - build.zig does not define an “example” build step, but README instructs zig build example.
  - Linking seems fine on macOS (static libs present and linked), so failure is from runtime calls (API usage/semantics) or error handling insufficient to diagnose.

  Major Correctness Issues

  - Row lifecycle leaks: QueryResult.next() returns Row but nothing ever destroys its kuzu_flat_tuple. The C API exposes kuzu_flat_tuple_destroy; it must be called. You have
  a current_row: ?Row field in QueryResult but it’s unused. This causes resource leaks as rows are iterated.
  - Memory management (strings/blobs) leaks:
      - QueryResult.getErrorMessage() returns a C string but doesn’t free it via kuzu_destroy_string.
      - QueryResult.getColumnName() returns a C string but doesn’t free it via kuzu_destroy_string.
      - Value.toString() returns a C string but doesn’t free it via kuzu_destroy_string.
      - Value.toBlob() returns a C-allocated buffer but doesn’t free it via kuzu_destroy_blob.
  - Value type mapping mismatch: ValueType is out of sync with kuzu_data_type_id.
      - Example: your NodeID = 13 but header has KUZU_SERIAL = 13 and KUZU_INTERNAL_ID = 42. You have Internal = 42 and an unsupported RdfVariant = 57. This can cause wrong
  type checks and downstream errors.
  - Wrong/obsolete function signatures:
      - QueryResult.getColumnDataType() calls kuzu_query_result_get_column_data_type as if it returns a type; per header it’s an out-parameter and returns a kuzu_state.
      - QueryResult.reset() calls kuzu_query_result_reset which doesn’t exist; the API is kuzu_query_result_reset_iterator.
      - QueryResult.getSummary() treats kuzu_query_result_get_query_summary as returning a summary; per header it’s an out-parameter and returns a kuzu_state.
  - Incomplete prepared-statement validation: after kuzu_connection_prepare, Kuzu returns a statement object which can be “unsuccessful”; you need to check
  kuzu_prepared_statement_is_success and possibly fetch kuzu_prepared_statement_get_error_message before returning.
  - Connection pool is broken:
      - Pool.acquire() returns Conn by value. Pool.release(self: *Pool, conn: Conn) compares @intFromPtr(&pooled.conn) with @intFromPtr(&conn). This compares different stack
  addresses, never matches, and leaves connections permanently “in use”. Pooling will exhaust.
      - withConnection() passes a pointer to a copied Conn stack value into the callback; release has the same pointer-identity problem.
      - Fix: return a pointer or index to the pooled entry, or compare underlying C handles (the _connection pointer inside c.kuzu_connection), and store handles in a way
  that release can identify.
  - Error surface is weak: checkState returns only error.Unknown on failure. It doesn’t attach/propagate the actual C error message when available, making diagnosis hard (as
  seen in test failure).

  API Coverage Gaps (high-value additions)

  - Typed getters for all supported types:
      - Unsigned ints (UInt8/16/32/64), Int128, Date, all Timestamp* flavors, Interval, Decimal (as string), UUID, Internal ID.
  - Composite types:
      - List/Array: size, element access (kuzu_value_get_list_size, get_list_element).
      - Struct: field count, names, value by index.
      - Map: size, key, and value access.
      - Node/Rel/RecursiveRel: property introspection via kuzu_node_val_* and kuzu_rel_val_*.
  - Query result utilities:
      - getNumTuples, multiple statement iteration (has_next_query_result, get_next_query_result), Arrow export (get_next_arrow_chunk).
  - Prepared statement typed binds:
      - Bind with kuzu_prepared_statement_bind_* instead of creating/destroying kuzu_value (saves allocations and matches API better).
  - System config parity:
      - Add macOS thread_qos field to SystemConfig (present in header).

  Tests: What’s Missing and How to Improve

  - Fix discovery so all tests run:
      - In build.zig, build tests from root_source_file = b.path("src/zkuzu.zig") (instead of root_module = zkuzu), or ensure the module import causes tests in submodules to
  be collected. Also consider std.testing.refAllDecls(@import("pool.zig")) in the root test to force inclusion.
  - Make the basic test diagnostic:
      - When a call fails, surface the C error message (e.g., if query_result.isSuccess is false, call getErrorMessage and free it).
      - Ensure the DB path you pass is acceptable to Kuzu. If Kuzu expects a directory rather than a “.db” file, use a folder path (e.g., zig-cache/zkuzu-test/db).
  - Add tests for:
      - Prepared statements: successful prepare/execute, unsuccessful prepare (error message checked and freed).
      - Typed getters: signed/unsigned ints, floats, Date/Timestamp/Interval/UUID/Decimal with expected conversions.
      - Composite values: lists, arrays, structs, maps; and a simple Node/Rel property test via MATCH ... RETURN n, r.
      - Null handling: check Row.isNull() and getters error on mismatched type.
      - Query summary: ensure getSummary() uses the correct API (out param) and returns times.
      - Iteration reset: call reset_iterator (correct function) and verify iteration restarts.
      - Timeouts and interrupts: set a low timeout or interrupt a long-running query (e.g., UNWIND range(...)) and assert failure/interrupt path.
      - Pool behavior: acquire/release correctness, exhaustion when at capacity, cleanup of idle connections.
      - Read-only config: open DB with read_only = true and assert writes fail.
      - Memory safety: add targeted tests that exercise repeated string/blob retrieval and check no leaks (free strings via kuzu_destroy_string, blobs via kuzu_destroy_blob,
  rows via kuzu_flat_tuple_destroy). Your current leak check uses std.testing.allocator_instance but most allocations are in Kuzu; instead, assert all returned C buffers
  are freed.

  Build/Packaging Improvements
      - Audit all c.kuzu_* signatures against the current kuzu.h.
  3. Fix ValueType to match kuzu_data_type_id exactly; add missing values and remove spurious ones.
  4. Harden prepared statements:
      - After prepare, check kuzu_prepared_statement_is_success; if false, get and free the error message and return a descriptive Zig error.
      - Add typed bind methods to avoid creating kuzu_value for primitives.
  5. Rewrite Pool to avoid copying Conn by value:
      - Use pointers/indices to pooled entries; ensure release identifies the exact pooled connection.
  6. Improve error reporting:
      - Enhance checkState call sites to capture and return error messages where available (e.g., for queries and prepared statements).
  7. Expand tests as outlined above and ensure test discovery includes all modules.
  8. Add the missing example build target in build.zig.

  Notes on the Current Failure

  - The failing test returns error.Unknown immediately; without fetching C error details, it’s hard to diagnose. The first failing call is likely DB initialization or an
  early query. Two likely causes:
      - Passing an unsuitable DB path (file name vs. directory). Prefer creating a directory path for the database (e.g., zig-cache/zkuzu-test/db).
      - API call mismatch leading to an internal error that’s being collapsed to Unknown. Address the API usage issues and surface error messages to pinpoint.

  If you want, I can:

  - Patch ValueType, fix the QueryResult API usage, add row and string/blob cleanup, and rewrite the pool to use pointers (plus add minimal tests to cover these paths).
  - Add an example target to build.zig and fix test discovery so the pool test runs.
