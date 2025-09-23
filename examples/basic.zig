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
    try conn.exec("CREATE NODE TABLE IF NOT EXISTS Person(name STRING, age INT64, email STRING, PRIMARY KEY(name))");
    try conn.exec("CREATE NODE TABLE IF NOT EXISTS Movie(title STRING, year INT64, rating DOUBLE, PRIMARY KEY(title))");

    // Create relationship tables
    try conn.exec("CREATE REL TABLE IF NOT EXISTS Likes(FROM Person TO Movie, score INT64)");
    try conn.exec("CREATE REL TABLE IF NOT EXISTS Knows(FROM Person TO Person, since INT64)");

    // Insert data
    std.debug.print("Inserting data...\n", .{});

    // Insert persons
    try conn.exec("MERGE (:Person {name: 'Alice', age: 30, email: 'alice@example.com'})");
    try conn.exec("MERGE (:Person {name: 'Bob', age: 25, email: 'bob@example.com'})");
    try conn.exec("MERGE (:Person {name: 'Charlie', age: 35, email: 'charlie@example.com'})");

    // Insert movies
    try conn.exec("MERGE (:Movie {title: 'The Matrix', year: 1999, rating: 8.7})");
    try conn.exec("MERGE (:Movie {title: 'Inception', year: 2010, rating: 8.8})");
    try conn.exec("MERGE (:Movie {title: 'Interstellar', year: 2014, rating: 8.6})");

    // Create relationships
    try conn.exec("MATCH (p:Person {name: 'Alice'}), (m:Movie {title: 'The Matrix'}) MERGE (p)-[:Likes {score: 9}]->(m)");
    try conn.exec("MATCH (p:Person {name: 'Alice'}), (m:Movie {title: 'Inception'}) MERGE (p)-[:Likes {score: 10}]->(m)");
    try conn.exec("MATCH (p:Person {name: 'Bob'}), (m:Movie {title: 'Inception'}) MERGE (p)-[:Likes {score: 8}]->(m)");
    try conn.exec("MATCH (p:Person {name: 'Bob'}), (m:Movie {title: 'Interstellar'}) MERGE (p)-[:Likes {score: 9}]->(m)");
    try conn.exec("MATCH (p:Person {name: 'Charlie'}), (m:Movie {title: 'The Matrix'}) MERGE (p)-[:Likes {score: 7}]->(m)");

    // Create knows relationships
    try conn.exec("MATCH (a:Person {name: 'Alice'}), (b:Person {name: 'Bob'}) MERGE (a)-[:Knows {since: 2020}]->(b)");
    try conn.exec("MATCH (b:Person {name: 'Bob'}), (c:Person {name: 'Charlie'}) MERGE (b)-[:Knows {since: 2021}]->(c)");

    // Query 1: Find all persons
    std.debug.print("\n--- All Persons ---\n", .{});
    var result = try conn.query("MATCH (p:Person) RETURN p.name, p.age, p.email ORDER BY p.name");

    while (try result.next()) |row_val| {
        const row = row_val;
        defer row.deinit();
        const name = try row.get([]const u8, 0);
        const age = try row.get(i64, 1);
        const email = try row.get([]const u8, 2);
        std.debug.print("Person: {s}, Age: {}, Email: {s}\n", .{ name, age, email });
    }
    result.deinit();

    // Query 2: Find movies liked by Alice
    std.debug.print("\n--- Movies liked by Alice ---\n", .{});
    var result2 = try conn.query(
        \\MATCH (p:Person {name: 'Alice'})-[l:Likes]->(m:Movie)
        \\RETURN m.title, m.year, l.score
        \\ORDER BY l.score DESC
    );

    while (try result2.next()) |row_val| {
        const row = row_val;
        defer row.deinit();
        const title = try row.get([]const u8, 0);
        const year = try row.get(i64, 1);
        const score = try row.get(i64, 2);
        std.debug.print("Movie: {s} ({}), Score: {}\n", .{ title, year, score });
    }
    result2.deinit();

    // Query 3: Find people who like the same movies
    std.debug.print("\n--- People who like the same movies ---\n", .{});
    var result3 = try conn.query(
        \\MATCH (p1:Person)-[:Likes]->(m:Movie)<-[:Likes]-(p2:Person)
        \\WHERE p1.name < p2.name
        \\RETURN DISTINCT p1.name, p2.name, COUNT(m) as common_movies
        \\ORDER BY common_movies DESC
    );

    while (try result3.next()) |row_val| {
        const row = row_val;
        defer row.deinit();
        const person1 = try row.get([]const u8, 0);
        const person2 = try row.get([]const u8, 1);
        const common = try row.get(i64, 2);
        std.debug.print("{s} and {s} like {} movies in common\n", .{ person1, person2, common });
    }
    result3.deinit();

    // Query 4: Find recommendation path
    std.debug.print("\n--- Recommendation Path ---\n", .{});
    var result4 = try conn.query(
        \\MATCH path = (p:Person {name: 'Alice'})-[:Knows*1..2]->(other:Person)
        \\RETURN other.name, LENGTH(path) as distance
        \\ORDER BY distance
    );

    while (try result4.next()) |row_val| {
        const row = row_val;
        defer row.deinit();
        const name = try row.get([]const u8, 0);
        const distance = try row.get(i64, 1);
        std.debug.print("Alice knows {s} with distance {}\n", .{ name, distance });
    }
    result4.deinit();

    // Using prepared statements
    std.debug.print("\n--- Using Prepared Statements ---\n", .{});
    var stmt = try conn.prepare("MATCH (p:Person {name: $name}) RETURN p.age, p.email");
    defer stmt.deinit();

    // Query for Bob
    try stmt.bindString("name", "Bob");
    var result5 = try stmt.execute();

    if (try result5.next()) |row_val| {
        const row = row_val;
        defer row.deinit();
        const age = try row.get(i64, 0);
        const email = try row.get([]const u8, 1);
        std.debug.print("Bob's age: {}, email: {s}\n", .{ age, email });
    }
    result5.deinit();

    // Transaction example
    std.debug.print("\n--- Transaction Example ---\n", .{});
    try conn.beginTransaction();

    try conn.exec("MERGE (:Person {name: 'David', age: 28, email: 'david@example.com'})");
    try conn.exec("MATCH (d:Person {name: 'David'}), (c:Person {name: 'Charlie'}) CREATE (d)-[:Knows {since: 2023}]->(c)");

    // Commit the transaction
    try conn.commit();
    std.debug.print("Transaction committed successfully\n", .{});

    // Verify David was added
    var result6 = try conn.query("MATCH (p:Person {name: 'David'}) RETURN p.age");

    if (try result6.next()) |row_val| {
        const row = row_val;
        defer row.deinit();
        const age = try row.get(i64, 0);
        std.debug.print("David was added with age: {}\n", .{age});
    }
    result6.deinit();

    // Get query statistics
    std.debug.print("\n--- Query Performance ---\n", .{});
    var result7 = try conn.query("MATCH (p:Person)-[:Likes]->(m:Movie) RETURN COUNT(*) as total_likes");

    if (try result7.next()) |row_val| {
        const row = row_val;
        defer row.deinit();
        const total = try row.get(i64, 0);
        std.debug.print("Total likes: {}\n", .{total});
    }
    const summary = try result7.getSummary();
    std.debug.print("Query compilation time: {d:.2}ms\n", .{summary.compiling_time_ms});
    std.debug.print("Query execution time: {d:.2}ms\n", .{summary.execution_time_ms});
    result7.deinit();

    std.debug.print("\n--- Error Handling Demo ---\n", .{});
    var invalid_result = blk: {
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
    if (invalid_result) |*qr_bad| {
        defer qr_bad.deinit();
        std.debug.print("Unexpected success for invalid query\n", .{});
    }

    std.debug.print("\nExample completed successfully!\n", .{});
}
