const std = @import("std");
const zkuzu = @import("zkuzu");

pub fn main() !void {
    // Database path
    const db_path = "example.db";

    // Create or open database
    std.debug.print("Opening database: {s}\n", .{db_path});
    var db = try zkuzu.open(db_path, null);
    defer db.deinit();

    // Create connection
    var conn = try db.connection();
    defer conn.deinit();

    // Create schema
    std.debug.print("\nCreating schema...\n", .{});

    // Create node tables
    _ = try conn.query("CREATE NODE TABLE IF NOT EXISTS Person(name STRING, age INT64, email STRING, PRIMARY KEY(name))");
    _ = try conn.query("CREATE NODE TABLE IF NOT EXISTS Movie(title STRING, year INT64, rating DOUBLE, PRIMARY KEY(title))");

    // Create relationship tables
    _ = try conn.query("CREATE REL TABLE IF NOT EXISTS Likes(FROM Person TO Movie, score INT64)");
    _ = try conn.query("CREATE REL TABLE IF NOT EXISTS Knows(FROM Person TO Person, since INT64)");

    // Insert data
    std.debug.print("Inserting data...\n", .{});

    // Insert persons
    _ = try conn.query("MERGE (:Person {name: 'Alice', age: 30, email: 'alice@example.com'})");
    _ = try conn.query("MERGE (:Person {name: 'Bob', age: 25, email: 'bob@example.com'})");
    _ = try conn.query("MERGE (:Person {name: 'Charlie', age: 35, email: 'charlie@example.com'})");

    // Insert movies
    _ = try conn.query("MERGE (:Movie {title: 'The Matrix', year: 1999, rating: 8.7})");
    _ = try conn.query("MERGE (:Movie {title: 'Inception', year: 2010, rating: 8.8})");
    _ = try conn.query("MERGE (:Movie {title: 'Interstellar', year: 2014, rating: 8.6})");

    // Create relationships
    _ = try conn.query("MATCH (p:Person {name: 'Alice'}), (m:Movie {title: 'The Matrix'}) MERGE (p)-[:Likes {score: 9}]->(m)");
    _ = try conn.query("MATCH (p:Person {name: 'Alice'}), (m:Movie {title: 'Inception'}) MERGE (p)-[:Likes {score: 10}]->(m)");
    _ = try conn.query("MATCH (p:Person {name: 'Bob'}), (m:Movie {title: 'Inception'}) MERGE (p)-[:Likes {score: 8}]->(m)");
    _ = try conn.query("MATCH (p:Person {name: 'Bob'}), (m:Movie {title: 'Interstellar'}) MERGE (p)-[:Likes {score: 9}]->(m)");
    _ = try conn.query("MATCH (p:Person {name: 'Charlie'}), (m:Movie {title: 'The Matrix'}) MERGE (p)-[:Likes {score: 7}]->(m)");

    // Create knows relationships
    _ = try conn.query("MATCH (a:Person {name: 'Alice'}), (b:Person {name: 'Bob'}) MERGE (a)-[:Knows {since: 2020}]->(b)");
    _ = try conn.query("MATCH (b:Person {name: 'Bob'}), (c:Person {name: 'Charlie'}) MERGE (b)-[:Knows {since: 2021}]->(c)");

    // Query 1: Find all persons
    std.debug.print("\n--- All Persons ---\n", .{});
    var result = try conn.query("MATCH (p:Person) RETURN p.name, p.age, p.email ORDER BY p.name");
    defer result.deinit();

    while (try result.next()) |row_val| {
        const row = row_val;
        defer row.deinit();
        const name = try row.getString(0);
        const age = try row.getInt(1);
        const email = try row.getString(2);
        std.debug.print("Person: {s}, Age: {}, Email: {s}\n", .{ name, age, email });
    }

    // Query 2: Find movies liked by Alice
    std.debug.print("\n--- Movies liked by Alice ---\n", .{});
    var result2 = try conn.query(
        \\MATCH (p:Person {name: 'Alice'})-[l:Likes]->(m:Movie)
        \\RETURN m.title, m.year, l.score
        \\ORDER BY l.score DESC
    );
    defer result2.deinit();

    while (try result2.next()) |row_val| {
        const row = row_val;
        defer row.deinit();
        const title = try row.getString(0);
        const year = try row.getInt(1);
        const score = try row.getInt(2);
        std.debug.print("Movie: {s} ({}), Score: {}\n", .{ title, year, score });
    }

    // Query 3: Find people who like the same movies
    std.debug.print("\n--- People who like the same movies ---\n", .{});
    var result3 = try conn.query(
        \\MATCH (p1:Person)-[:Likes]->(m:Movie)<-[:Likes]-(p2:Person)
        \\WHERE p1.name < p2.name
        \\RETURN DISTINCT p1.name, p2.name, COUNT(m) as common_movies
        \\ORDER BY common_movies DESC
    );
    defer result3.deinit();

    while (try result3.next()) |row_val| {
        const row = row_val;
        defer row.deinit();
        const person1 = try row.getString(0);
        const person2 = try row.getString(1);
        const common = try row.getInt(2);
        std.debug.print("{s} and {s} like {} movies in common\n", .{ person1, person2, common });
    }

    // Query 4: Find recommendation path
    std.debug.print("\n--- Recommendation Path ---\n", .{});
    var result4 = try conn.query(
        \\MATCH path = (p:Person {name: 'Alice'})-[:Knows*1..2]->(other:Person)
        \\RETURN other.name, LENGTH(path) as distance
        \\ORDER BY distance
    );
    defer result4.deinit();

    while (try result4.next()) |row_val| {
        const row = row_val;
        defer row.deinit();
        const name = try row.getString(0);
        const distance = try row.getInt(1);
        std.debug.print("Alice knows {s} with distance {}\n", .{ name, distance });
    }

    // Using prepared statements
    std.debug.print("\n--- Using Prepared Statements ---\n", .{});
    var stmt = try conn.prepare("MATCH (p:Person {name: $name}) RETURN p.age, p.email");
    defer stmt.deinit();

    // Query for Bob
    try stmt.bindString("name", "Bob");
    var result5 = try stmt.execute();
    defer result5.deinit();

    if (try result5.next()) |row_val| {
        const row = row_val;
        defer row.deinit();
        const age = try row.getInt(0);
        const email = try row.getString(1);
        std.debug.print("Bob's age: {}, email: {s}\n", .{ age, email });
    }

    // Transaction example
    std.debug.print("\n--- Transaction Example ---\n", .{});
    try conn.beginTransaction();

    _ = try conn.query("CREATE (:Person {name: 'David', age: 28, email: 'david@example.com'})");
    _ = try conn.query("MATCH (d:Person {name: 'David'}), (c:Person {name: 'Charlie'}) CREATE (d)-[:Knows {since: 2023}]->(c)");

    // Commit the transaction
    try conn.commit();
    std.debug.print("Transaction committed successfully\n", .{});

    // Verify David was added
    var result6 = try conn.query("MATCH (p:Person {name: 'David'}) RETURN p.age");
    defer result6.deinit();

    if (try result6.next()) |row_val| {
        const row = row_val;
        defer row.deinit();
        const age = try row.getInt(0);
        std.debug.print("David was added with age: {}\n", .{age});
    }

    // Get query statistics
    std.debug.print("\n--- Query Performance ---\n", .{});
    var result7 = try conn.query("MATCH (p:Person)-[:Likes]->(m:Movie) RETURN COUNT(*) as total_likes");
    defer result7.deinit();

    if (try result7.next()) |row_val| {
        const row = row_val;
        defer row.deinit();
        const total = try row.getInt(0);
        std.debug.print("Total likes: {}\n", .{total});
    }

    const summary = try result7.getSummary();
    std.debug.print("Query compilation time: {d:.2}ms\n", .{summary.compiling_time_ms});
    std.debug.print("Query execution time: {d:.2}ms\n", .{summary.execution_time_ms});

    std.debug.print("\n--- Error Handling Demo ---\n", .{});
    const invalid_result = blk: {
        const res = conn.query("RETURN 1 +") catch |err| switch (err) {
            zkuzu.Error.QueryFailed => {
                if (conn.lastErrorMessage()) |msg| {
                    std.debug.print("Expected failure: {s}\n", .{msg});
                } else {
                    std.debug.print("Expected failure but no message available\n", .{});
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

    std.debug.print("\nExample completed successfully!\n", .{});
}
