const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    // Kuzu uses C++ exceptions which can cause issues with Zig's test runner
    // We'll run tests with proper error handling

    const test_list = builtin.test_functions;
    var pass: usize = 0;
    const skip: usize = 0;
    var fail: usize = 0;

    for (test_list, 0..) |test_fn, i| {
        var status: []const u8 = "PASS";

        std.testing.allocator_instance = .{};
        defer {
            if (std.testing.allocator_instance.deinit() == .leak) {
                status = "LEAK";
                fail += 1;
            }
        }

        // Print test name
        std.debug.print("[{}/{}] {s}...", .{ i + 1, test_list.len, test_fn.name });

        // Run the test
        test_fn.func() catch |err| {
            status = "FAIL";
            fail += 1;
            std.debug.print(" {s}: {}\n", .{ status, err });
            continue;
        };

        if (std.mem.eql(u8, status, "PASS")) {
            pass += 1;
            std.debug.print(" {s}\n", .{status});
        }
    }

    // Print summary
    std.debug.print("\n", .{});
    std.debug.print("Test Summary:\n", .{});
    std.debug.print("  Passed: {}\n", .{pass});
    std.debug.print("  Failed: {}\n", .{fail});
    std.debug.print("  Skipped: {}\n", .{skip});
    std.debug.print("  Total: {}\n", .{test_list.len});

    if (fail > 0) {
        std.process.exit(1);
    }
}
