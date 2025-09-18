const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_path = b.path("lib");

    // Main zkuzu module
    const zkuzu = b.addModule("zkuzu", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zkuzu.addIncludePath(lib_path);

    // Test executable
    const lib_test = b.addTest(.{
        .root_module = zkuzu,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });

    // Link Kuzu library and dependencies
    lib_test.addObjectFile(b.path("lib/libkuzu.a"));

    // Link third-party libraries that Kuzu depends on
    lib_test.addObjectFile(b.path("lib/libbrotlidec.a"));
    lib_test.addObjectFile(b.path("lib/libbrotlienc.a"));
    lib_test.addObjectFile(b.path("lib/libbrotlicommon.a"));
    lib_test.addObjectFile(b.path("lib/libfastpfor.a"));
    lib_test.addObjectFile(b.path("lib/libantlr4_runtime.a"));
    lib_test.addObjectFile(b.path("lib/libantlr4_cypher.a"));
    lib_test.addObjectFile(b.path("lib/libre2.a"));
    lib_test.addObjectFile(b.path("lib/libutf8proc.a"));
    lib_test.addObjectFile(b.path("lib/libzstd.a"));
    lib_test.addObjectFile(b.path("lib/libsnappy.a"));
    lib_test.addObjectFile(b.path("lib/liblz4.a"));
    lib_test.addObjectFile(b.path("lib/libminiz.a"));
    lib_test.addObjectFile(b.path("lib/libmbedtls.a"));
    lib_test.addObjectFile(b.path("lib/libthrift.a"));
    lib_test.addObjectFile(b.path("lib/libparquet.a"));
    lib_test.addObjectFile(b.path("lib/libroaring_bitmap.a"));
    lib_test.addObjectFile(b.path("lib/libsimsimd.a"));
    lib_test.addObjectFile(b.path("lib/libyyjson.a"));

    lib_test.addIncludePath(lib_path);

    // Link required system libraries
    lib_test.linkLibC();
    lib_test.linkLibCpp();

    // Platform-specific linking
    const os_tag = target.query.os_tag orelse @import("builtin").os.tag;
    switch (os_tag) {
        .linux => {
            lib_test.linkSystemLibrary("pthread");
            lib_test.linkSystemLibrary("dl");
            lib_test.linkSystemLibrary("m");
        },
        .macos => {
            lib_test.linkFramework("Foundation");
            lib_test.linkSystemLibrary("pthread");
            lib_test.linkSystemLibrary("m");
        },
        .windows => {
            lib_test.linkSystemLibrary("ws2_32");
            lib_test.linkSystemLibrary("bcrypt");
        },
        else => {},
    }

    const run_test = b.addRunArtifact(lib_test);
    run_test.has_side_effects = true;

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_test.step);

    // Examples: basic
    const ex_basic = b.addExecutable(.{
        .name = "zkuzu-basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ex_basic.root_module.addImport("zkuzu", zkuzu);
    zkuzu.addIncludePath(lib_path);
    ex_basic.addIncludePath(lib_path);
    ex_basic.addObjectFile(b.path("lib/libkuzu.a"));
    ex_basic.addObjectFile(b.path("lib/libbrotlidec.a"));
    ex_basic.addObjectFile(b.path("lib/libbrotlienc.a"));
    ex_basic.addObjectFile(b.path("lib/libbrotlicommon.a"));
    ex_basic.addObjectFile(b.path("lib/libfastpfor.a"));
    ex_basic.addObjectFile(b.path("lib/libantlr4_runtime.a"));
    ex_basic.addObjectFile(b.path("lib/libantlr4_cypher.a"));
    ex_basic.addObjectFile(b.path("lib/libre2.a"));
    ex_basic.addObjectFile(b.path("lib/libutf8proc.a"));
    ex_basic.addObjectFile(b.path("lib/libzstd.a"));
    ex_basic.addObjectFile(b.path("lib/libsnappy.a"));
    ex_basic.addObjectFile(b.path("lib/liblz4.a"));
    ex_basic.addObjectFile(b.path("lib/libminiz.a"));
    ex_basic.addObjectFile(b.path("lib/libmbedtls.a"));
    ex_basic.addObjectFile(b.path("lib/libthrift.a"));
    ex_basic.addObjectFile(b.path("lib/libparquet.a"));
    ex_basic.addObjectFile(b.path("lib/libroaring_bitmap.a"));
    ex_basic.addObjectFile(b.path("lib/libsimsimd.a"));
    ex_basic.addObjectFile(b.path("lib/libyyjson.a"));
    ex_basic.linkLibC();
    ex_basic.linkLibCpp();
    switch (os_tag) {
        .linux => {
            ex_basic.linkSystemLibrary("pthread");
            ex_basic.linkSystemLibrary("dl");
            ex_basic.linkSystemLibrary("m");
        },
        .macos => {
            ex_basic.linkFramework("Foundation");
            ex_basic.linkSystemLibrary("pthread");
            ex_basic.linkSystemLibrary("m");
        },
        .windows => {
            ex_basic.linkSystemLibrary("ws2_32");
            ex_basic.linkSystemLibrary("bcrypt");
        },
        else => {},
    }
    const run_basic = b.addRunArtifact(ex_basic);
    run_basic.step.dependOn(b.getInstallStep());

    const example_basic_step = b.step("example-basic", "Build and run basic example");
    example_basic_step.dependOn(&run_basic.step);

    // Examples: prepared/typed
    const ex_prepared = b.addExecutable(.{
        .name = "zkuzu-prepared",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/prepared.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ex_prepared.root_module.addImport("zkuzu", zkuzu);
    ex_prepared.addIncludePath(lib_path);
    ex_prepared.addObjectFile(b.path("lib/libkuzu.a"));
    ex_prepared.addObjectFile(b.path("lib/libbrotlidec.a"));
    ex_prepared.addObjectFile(b.path("lib/libbrotlienc.a"));
    ex_prepared.addObjectFile(b.path("lib/libbrotlicommon.a"));
    ex_prepared.addObjectFile(b.path("lib/libfastpfor.a"));
    ex_prepared.addObjectFile(b.path("lib/libantlr4_runtime.a"));
    ex_prepared.addObjectFile(b.path("lib/libantlr4_cypher.a"));
    ex_prepared.addObjectFile(b.path("lib/libre2.a"));
    ex_prepared.addObjectFile(b.path("lib/libutf8proc.a"));
    ex_prepared.addObjectFile(b.path("lib/libzstd.a"));
    ex_prepared.addObjectFile(b.path("lib/libsnappy.a"));
    ex_prepared.addObjectFile(b.path("lib/liblz4.a"));
    ex_prepared.addObjectFile(b.path("lib/libminiz.a"));
    ex_prepared.addObjectFile(b.path("lib/libmbedtls.a"));
    ex_prepared.addObjectFile(b.path("lib/libthrift.a"));
    ex_prepared.addObjectFile(b.path("lib/libparquet.a"));
    ex_prepared.addObjectFile(b.path("lib/libroaring_bitmap.a"));
    ex_prepared.addObjectFile(b.path("lib/libsimsimd.a"));
    ex_prepared.addObjectFile(b.path("lib/libyyjson.a"));
    ex_prepared.linkLibC();
    ex_prepared.linkLibCpp();
    switch (os_tag) {
        .linux => {
            ex_prepared.linkSystemLibrary("pthread");
            ex_prepared.linkSystemLibrary("dl");
            ex_prepared.linkSystemLibrary("m");
        },
        .macos => {
            ex_prepared.linkFramework("Foundation");
            ex_prepared.linkSystemLibrary("pthread");
            ex_prepared.linkSystemLibrary("m");
        },
        .windows => {
            ex_prepared.linkSystemLibrary("ws2_32");
            ex_prepared.linkSystemLibrary("bcrypt");
        },
        else => {},
    }
    const run_prepared = b.addRunArtifact(ex_prepared);
    run_prepared.step.dependOn(b.getInstallStep());
    const example_prepared_step = b.step("example-prepared", "Build and run prepared example");
    example_prepared_step.dependOn(&run_prepared.step);
}
