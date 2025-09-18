const std = @import("std");
const zkuzu = @import("../root.zig");

test "basic database operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp_dir = try std.fs.cwd().makeOpenPath("zig-cache/zkuzu-test", .{});
    defer tmp_dir.close();

    const db_path = try zkuzu.toCString(allocator, "zig-cache/zkuzu-test/db");
    defer allocator.free(db_path);

    var db = try zkuzu.open(db_path, null);
    defer db.deinit();

    var connection_handle = try db.connection();
    defer connection_handle.deinit();

    std.debug.print("creating Person table...\n", .{});
    var _q0 = try connection_handle.query("CREATE NODE TABLE IF NOT EXISTS Person(name STRING, age INT64, PRIMARY KEY(name))");
    _q0.deinit();
    std.debug.print("creating Knows table...\n", .{});
    var _q1 = try connection_handle.query("CREATE REL TABLE IF NOT EXISTS Knows(FROM Person TO Person)");
    _q1.deinit();

    std.debug.print("inserting Alice...\n", .{});
    var _iq0 = try connection_handle.query("MERGE (:Person {name: 'Alice', age: 30})");
    _iq0.deinit();
    std.debug.print("inserting Bob...\n", .{});
    var _iq1 = try connection_handle.query("MERGE (:Person {name: 'Bob', age: 25})");
    _iq1.deinit();
    std.debug.print("creating relationship...\n", .{});
    var _iq2 = try connection_handle.query("MATCH (a:Person {name: 'Alice'}), (b:Person {name: 'Bob'}) CREATE (a)-[:Knows]->(b)");
    _iq2.deinit();

    std.debug.print("querying persons...\n", .{});
    var result = try connection_handle.query("MATCH (p:Person) RETURN p.name, p.age ORDER BY p.age");
    defer result.deinit();

    var count: usize = 0;
    while (try result.next()) |row_val| {
        const row = row_val;
        defer row.deinit();
        const name = try row.getString(0);
        const age = try row.getInt(1);

        if (count == 0) {
            try testing.expectEqualStrings("Bob", name);
            try testing.expectEqual(@as(i64, 25), age);
        } else if (count == 1) {
            try testing.expectEqualStrings("Alice", name);
            try testing.expectEqual(@as(i64, 30), age);
        }
        count += 1;
    }

    try testing.expectEqual(@as(usize, 2), count);
}

test "prepared statements, name getters, exec and transactions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    _ = try std.fs.cwd().makeOpenPath("zig-cache/zkuzu-ps-test", .{});
    const db_path = try zkuzu.toCString(allocator, "zig-cache/zkuzu-ps-test/db");
    defer allocator.free(db_path);

    var db = try zkuzu.open(db_path, null);
    defer db.deinit();
    var connection_handle = try db.connection();
    defer connection_handle.deinit();

    std.debug.print("ps-test: create table...\n", .{});
    try connection_handle.exec("CREATE NODE TABLE IF NOT EXISTS Member(name STRING, age INT64, PRIMARY KEY(name))");

    std.debug.print("ps-test: insert rows...\n", .{});
    try connection_handle.exec("MERGE (:Member {name:'Ann', age: 21})");
    try connection_handle.exec("MERGE (:Member {name:'Ben', age: 35})");

    std.debug.print("ps-test: prepare...\n", .{});
    var ps = try connection_handle.prepare("MATCH (u:Member) WHERE u.age > $min_age RETURN u.name AS name, u.age AS age ORDER BY age");
    defer ps.deinit();
    std.debug.print("ps-test: bind...\n", .{});
    try ps.bindInt("min_age", 30);
    std.debug.print("ps-test: execute...\n", .{});
    var qr = try ps.execute();
    defer qr.deinit();

    var seen: usize = 0;
    while (try qr.next()) |row_val| {
        const row = row_val;
        defer row.deinit();
        const name = try row.getStringByName("name");
        const age = try row.getIntByName("age");
        _ = name;
        try testing.expect(age > 30);
        seen += 1;
    }

    try testing.expectEqual(@as(usize, 1), seen);

    std.debug.print("ps-test: execute with null min_age...\n", .{});
    try connection_handle.exec("MERGE (:Member {name:'Cara', age: 28})");
    var ps_null = try connection_handle.prepare("MATCH (u:Member) WHERE u.age > $min RETURN u.name");
    defer ps_null.deinit();
    try ps_null.bindNull("min", zkuzu.c.KUZU_INT64);
    var qr_null = try ps_null.execute();
    defer qr_null.deinit();
    const row_opt = try qr_null.next();
    try testing.expectEqual(@as(?*zkuzu.Row, null), row_opt);

    try connection_handle.beginTransaction();
    try connection_handle.exec("MERGE (:Member {name:'Dax', age: 41})");
    try connection_handle.rollback();

    var check_qr = try connection_handle.query("MATCH (u:Member {name:'Dax'}) RETURN u.name");
    defer check_qr.deinit();
    try testing.expectEqual(@as(?*zkuzu.Row, null), try check_qr.next());

    const msg_after_success = connection_handle.lastErrorMessage();
    try testing.expectEqual(@as(?[]const u8, null), msg_after_success);
}

test "composite value and graph accessors" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp_dir = try std.fs.cwd().makeOpenPath("zig-cache/zkuzu-more-types", .{});
    defer tmp_dir.close();

    const db_path = try zkuzu.toCString(allocator, "zig-cache/zkuzu-more-types/db");
    defer allocator.free(db_path);

    var db = try zkuzu.open(db_path, null);
    defer db.deinit();

    var conn = try db.connection();
    defer conn.deinit();

    try conn.exec(
        "CREATE NODE TABLE IF NOT EXISTS Person(name STRING, age INT64, tags STRING[], PRIMARY KEY(name))",
    );
    try conn.exec(
        "CREATE REL TABLE IF NOT EXISTS Knows(FROM Person TO Person, since INT64)",
    );

    try conn.exec("MERGE (:Person {name:'Alice', age: 30, tags:['founder','ceo']})");
    try conn.exec("MERGE (:Person {name:'Bob', age: 25, tags:['engineer']})");
    try conn.exec("MERGE (:Person {name:'Cara', age: 28, tags:['designer']})");
    try conn.exec(
        "MATCH (a:Person {name:'Alice'}), (b:Person {name:'Bob'}) MERGE (a)-[:Knows {since:2020}]->(b)",
    );
    try conn.exec(
        "MATCH (b:Person {name:'Bob'}), (c:Person {name:'Cara'}) MERGE (b)-[:Knows {since:2021}]->(c)",
    );

    var qr = try conn.query("MATCH (a:Person {name:'Alice'})-[r:Knows]->(b:Person)\n" ++ "RETURN range(1,3) AS ints, collect(b.name) AS friends, a AS node, r AS rel\n" ++ "LIMIT 1");
    defer qr.deinit();

    const row_opt = try qr.next();
    try testing.expect(row_opt != null);
    var row = row_opt.?;
    defer row.deinit();

    // List of ints
    var ints_val = try row.getValue(0);
    defer ints_val.deinit();
    try testing.expectEqual(zkuzu.ValueType.List, ints_val.getType());
    const ints_len = try ints_val.getListLength();
    try testing.expectEqual(@as(u64, 3), ints_len);
    var first_int = try ints_val.getListElement(0);
    defer first_int.deinit();
    try testing.expectEqual(@as(i64, 1), try first_int.toInt());

    // List of friend names (strings)
    var friends_val = try row.getValue(1);
    defer friends_val.deinit();
    try testing.expectEqual(zkuzu.ValueType.List, friends_val.getType());
    const friends_len = try friends_val.getListLength();
    try testing.expect(friends_len >= 1);
    var friend0 = try friends_val.getListElement(0);
    defer friend0.deinit();
    const friend_name = try friend0.toString();
    try testing.expect(friend_name.len > 0);

    // Node view helpers
    var node_val = try row.getValue(2);
    defer node_val.deinit();
    try testing.expectEqual(zkuzu.ValueType.Node, node_val.getType());
    const node_view = try node_val.asNode();
    var node_label_val = try node_view.labelValue();
    defer node_label_val.deinit();
    try testing.expectEqualStrings("Person", try node_label_val.toString());
    _ = try node_view.idValue(); // just ensure it succeeds
    const node_prop_count = try node_view.propertyCount();
    try testing.expect(node_prop_count >= 3);
    const struct_field_count = try node_val.getStructFieldCount();
    try testing.expect(struct_field_count >= 3);
    const struct_field_name = try node_val.copyStructFieldName(allocator, 0);
    defer allocator.free(struct_field_name);
    try testing.expect(struct_field_name.len > 0);

    var node_saw_name = false;
    var node_prop_index: u64 = 0;
    while (node_prop_index < node_prop_count) : (node_prop_index += 1) {
        const prop_name = try node_view.propertyName(node_prop_index);
        var prop_val = try node_view.propertyValue(node_prop_index);
        defer prop_val.deinit();
        if (std.mem.eql(u8, prop_name, "name")) {
            try testing.expectEqualStrings("Alice", try prop_val.toString());
            node_saw_name = true;
        }
    }
    try testing.expect(node_saw_name);

    // Extract properties map via struct field
    var struct_map_index: u64 = 0;
    var props_val_opt: ?zkuzu.Value = null;
    while (struct_map_index < struct_field_count) : (struct_map_index += 1) {
        const field_name = try node_val.getStructFieldName(struct_map_index);
        if (std.ascii.eqlIgnoreCase(field_name, "properties")) {
            props_val_opt = try node_val.getStructFieldValue(struct_map_index);
            break;
        }
    }
    if (props_val_opt) |*props_val| {
        defer props_val.deinit();
        try testing.expectEqual(zkuzu.ValueType.Map, props_val.getType());
        const props_len = try props_val.getMapSize();
        try testing.expect(props_len >= 3);
        var saw_age = false;
        var map_index: u64 = 0;
        while (map_index < props_len) : (map_index += 1) {
            var key_val = try props_val.getMapKey(map_index);
            defer key_val.deinit();
            const key = try key_val.toString();
            var value_val = try props_val.getMapValue(map_index);
            defer value_val.deinit();
            if (std.mem.eql(u8, key, "age")) {
                try testing.expectEqual(@as(i64, 30), try value_val.toInt());
                saw_age = true;
            }
        }
        try testing.expect(saw_age);
    }

    // Relationship helpers
    var rel_val = try row.getValue(3);
    defer rel_val.deinit();
    try testing.expectEqual(zkuzu.ValueType.Rel, rel_val.getType());
    const rel_view = try rel_val.asRel();
    var rel_label_val = try rel_view.labelValue();
    defer rel_label_val.deinit();
    try testing.expectEqualStrings("Knows", try rel_label_val.toString());
    _ = try rel_view.idValue();
    _ = try rel_view.srcIdValue();
    _ = try rel_view.dstIdValue();
    const rel_prop_count = try rel_view.propertyCount();
    try testing.expect(rel_prop_count >= 1);
    const rel_prop_name_copy = try rel_view.copyPropertyName(allocator, 0);
    defer allocator.free(rel_prop_name_copy);

    // Recursive relationship (path) helpers
    var path_qr = try conn.query("MATCH p = (:Person {name:'Alice'})-[:Knows*1..2]->(:Person)\n" ++ "RETURN p\n" ++ "LIMIT 1");
    defer path_qr.deinit();
    if (try path_qr.next()) |path_row_ptr| {
        const path_row = path_row_ptr;
        defer path_row.deinit();
        var path_val = try path_row.getValue(0);
        defer path_val.deinit();
        try testing.expectEqual(zkuzu.ValueType.RecursiveRel, path_val.getType());
        const recursive = try path_val.asRecursiveRel();
        var nodes_list = try recursive.nodeList();
        defer nodes_list.deinit();
        const nodes_len = try nodes_list.getListLength();
        try testing.expect(nodes_len >= 2);
        var rels_list = try recursive.relList();
        defer rels_list.deinit();
        const rels_len = try rels_list.getListLength();
        try testing.expect(rels_len >= 1);
    }
}

