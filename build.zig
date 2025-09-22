const std = @import("std");

fn pathExists(b: *std.Build, rel: []const u8) bool {
    const p = b.path(rel).getPath(b);
    std.fs.cwd().access(p, .{}) catch return false;
    return true;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const slow_tests = b.option(bool, "slow-tests", "Enable slow/unstable tests (interrupt/timeout)") orelse false;

    const lib_path = b.path("lib");
    const kuzu_provider = b.option([]const u8, "kuzu-provider", "kuzu provider: prebuilt|system|local|source") orelse "prebuilt";
    const kuzu_system_include_opt = b.option([]const u8, "kuzu-include-dir", "Path to kuzu headers (kuzu.h)");
    const kuzu_system_libdir_opt = b.option([]const u8, "kuzu-lib-dir", "Path to directory containing libkuzu.{dylib,so,lib}");

    const have_static = pathExists(b, "lib/libkuzu.a");
    const have_dylib = pathExists(b, "lib/libkuzu.dylib");
    const have_so = pathExists(b, "lib/libkuzu.so");
    const have_win = pathExists(b, "lib/kuzu_shared.dll") and pathExists(b, "lib/kuzu_shared.lib");
    const local_use_shared = (!have_static) and (have_dylib or have_so or have_win);

    var resolved_include: ?std.Build.LazyPath = null;
    var resolved_libdir: ?std.Build.LazyPath = null;
    var resolved_libname: ?[]const u8 = null;

    const os_tag = target.query.os_tag orelse @import("builtin").os.tag;
    const arch_tag = target.query.cpu_arch orelse @import("builtin").cpu.arch;

    var source_build_step: ?*std.Build.Step.Run = null;
    if (std.mem.eql(u8, kuzu_provider, "prebuilt")) {
        const dep_name: []const u8 = switch (os_tag) {
            .macos => "kuzu_osx",
            .linux => switch (arch_tag) {
                .x86_64 => "kuzu_linux_x86_64",
                .aarch64 => "kuzu_linux_aarch64",
                else => @panic("Unsupported linux arch for prebuilt kuzu"),
            },
            .windows => "kuzu_win_x86_64",
            else => @panic("Unsupported OS for prebuilt kuzu"),
        };
        const kuzu_dep = b.dependency(dep_name, .{ .target = target, .optimize = optimize });
        const kuzu_root = kuzu_dep.path(".");
        resolved_include = kuzu_root;
        resolved_libdir = kuzu_root;
        resolved_libname = if (os_tag == .windows) "kuzu_shared" else "kuzu";
    } else if (std.mem.eql(u8, kuzu_provider, "system")) {
        if (kuzu_system_include_opt) |p| resolved_include = b.path(p);
        if (kuzu_system_libdir_opt) |p| resolved_libdir = b.path(p);
        resolved_libname = if (os_tag == .windows) "kuzu_shared" else "kuzu";
    } else if (std.mem.eql(u8, kuzu_provider, "source")) {
        const src_dep = b.dependency("kuzu_src", .{ .target = target, .optimize = optimize });
        const src_root = src_dep.path(".");
        const cmake_prog = [_][]const u8{"cmake"};
        const empty_paths = [_][]const u8{};
        const cmake = b.findProgram(&cmake_prog, &empty_paths) catch @panic("CMake not found. Install CMake or use -Dkuzu-provider=prebuilt/system/local");

        const cache_root = b.cache_root.path orelse ".zig-cache";
        const build_dir = b.fmt("{s}/kuzu-src-build", .{cache_root});
        const src_path = src_root.getPath(b);

        const cfg = b.addSystemCommand(&.{
            cmake,
            "-S",
            src_path,
            "-B",
            build_dir,
            "-DCMAKE_BUILD_TYPE=Release",
            "-DBUILD_KUZU_SHELL=OFF",
            "-DBUILD_SHARED_LIBS=ON",
            "-DCMAKE_CXX_FLAGS=-Wno-error=date-time",
        });
        cfg.setEnvironmentVariable("CC", "zig cc");
        cfg.setEnvironmentVariable("CXX", "zig c++");

        const cmake_build = b.addSystemCommand(&.{ cmake, "--build", build_dir, "--config", "Release" });
        cmake_build.step.dependOn(&cfg.step);
        source_build_step = cmake_build;

        resolved_include = .{ .cwd_relative = b.fmt("{s}/src/include/c_api", .{src_path}) };
        resolved_libdir = .{ .cwd_relative = b.fmt("{s}/src", .{build_dir}) };
        resolved_libname = if (os_tag == .windows) "kuzu_shared" else "kuzu";
    } else if (std.mem.eql(u8, kuzu_provider, "local")) {
        resolved_include = lib_path;
        resolved_libdir = lib_path;
        resolved_libname = if (local_use_shared and os_tag == .windows) "kuzu_shared" else "kuzu";
    } else {
        @panic("Unknown kuzu-provider; use prebuilt|system|local");
    }

    // Main zkuzu module
    const zkuzu = b.addModule("zkuzu", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Build options accessible from source via @import("build_options")
    const build_options = b.addOptions();
    build_options.addOption(bool, "slow_tests", slow_tests);
    zkuzu.addOptions("build_options", build_options);
    if (resolved_include) |inc| zkuzu.addIncludePath(inc) else zkuzu.addIncludePath(lib_path);

    // Test executable
    const lib_test = b.addTest(.{
        .root_module = zkuzu,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    if (source_build_step) |sb| lib_test.step.dependOn(&sb.step);

    // Link Kuzu library
    if (std.mem.eql(u8, kuzu_provider, "local") and !local_use_shared) {
        lib_test.addObjectFile(b.path("lib/libkuzu.a"));
        // Third-party static dependencies (only when using static build)
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
    } else {
        if (resolved_libdir) |ld| lib_test.addLibraryPath(ld);
        if (resolved_libname) |ln| lib_test.linkSystemLibrary(ln);
    }

    lib_test.addIncludePath(lib_path);

    // Link required system libraries
    lib_test.linkLibC();
    lib_test.linkLibCpp();

    // Platform-specific linking
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
    if (!(std.mem.eql(u8, kuzu_provider, "local") and !local_use_shared)) {
        if (resolved_libdir) |ld| {
            if (os_tag == .macos) run_test.setEnvironmentVariable("DYLD_LIBRARY_PATH", ld.getPath(b)) else if (os_tag == .linux) run_test.setEnvironmentVariable("LD_LIBRARY_PATH", ld.getPath(b)) else if (os_tag == .windows) run_test.setEnvironmentVariable("PATH", ld.getPath(b));
        }
    }

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
    if (source_build_step) |sb| ex_basic.step.dependOn(&sb.step);
    ex_basic.root_module.addImport("zkuzu", zkuzu);
    if (resolved_include) |inc| ex_basic.addIncludePath(inc) else ex_basic.addIncludePath(lib_path);
    if (std.mem.eql(u8, kuzu_provider, "local") and !local_use_shared) {
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
    } else {
        if (resolved_libdir) |ld| ex_basic.addLibraryPath(ld);
        if (resolved_libname) |ln| ex_basic.linkSystemLibrary(ln);
    }
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
    if (!(std.mem.eql(u8, kuzu_provider, "local") and !local_use_shared)) {
        if (resolved_libdir) |ld| {
            if (os_tag == .macos) run_basic.setEnvironmentVariable("DYLD_LIBRARY_PATH", ld.getPath(b)) else if (os_tag == .linux) run_basic.setEnvironmentVariable("LD_LIBRARY_PATH", ld.getPath(b)) else if (os_tag == .windows) run_basic.setEnvironmentVariable("PATH", ld.getPath(b));
        }
    }

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
    if (source_build_step) |sb| ex_prepared.step.dependOn(&sb.step);
    ex_prepared.root_module.addImport("zkuzu", zkuzu);
    if (resolved_include) |inc| ex_prepared.addIncludePath(inc) else ex_prepared.addIncludePath(lib_path);
    if (std.mem.eql(u8, kuzu_provider, "local") and !local_use_shared) {
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
    } else {
        if (resolved_libdir) |ld| ex_prepared.addLibraryPath(ld);
        if (resolved_libname) |ln| ex_prepared.linkSystemLibrary(ln);
    }
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
    if (!(std.mem.eql(u8, kuzu_provider, "local") and !local_use_shared)) {
        if (resolved_libdir) |ld| {
            if (os_tag == .macos) run_prepared.setEnvironmentVariable("DYLD_LIBRARY_PATH", ld.getPath(b)) else if (os_tag == .linux) run_prepared.setEnvironmentVariable("LD_LIBRARY_PATH", ld.getPath(b)) else if (os_tag == .windows) run_prepared.setEnvironmentVariable("PATH", ld.getPath(b));
        }
    }
    const example_prepared_step = b.step("example-prepared", "Build and run prepared example");
    example_prepared_step.dependOn(&run_prepared.step);

    // Examples: transactions
    const ex_tx = b.addExecutable(.{
        .name = "zkuzu-transactions",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/transactions.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (source_build_step) |sb| ex_tx.step.dependOn(&sb.step);
    ex_tx.root_module.addImport("zkuzu", zkuzu);
    if (resolved_include) |inc| ex_tx.addIncludePath(inc) else ex_tx.addIncludePath(lib_path);
    if (std.mem.eql(u8, kuzu_provider, "local") and !local_use_shared) {
        ex_tx.addObjectFile(b.path("lib/libkuzu.a"));
        ex_tx.addObjectFile(b.path("lib/libbrotlidec.a"));
        ex_tx.addObjectFile(b.path("lib/libbrotlienc.a"));
        ex_tx.addObjectFile(b.path("lib/libbrotlicommon.a"));
        ex_tx.addObjectFile(b.path("lib/libfastpfor.a"));
        ex_tx.addObjectFile(b.path("lib/libantlr4_runtime.a"));
        ex_tx.addObjectFile(b.path("lib/libantlr4_cypher.a"));
        ex_tx.addObjectFile(b.path("lib/libre2.a"));
        ex_tx.addObjectFile(b.path("lib/libutf8proc.a"));
        ex_tx.addObjectFile(b.path("lib/libzstd.a"));
        ex_tx.addObjectFile(b.path("lib/libsnappy.a"));
        ex_tx.addObjectFile(b.path("lib/liblz4.a"));
        ex_tx.addObjectFile(b.path("lib/libminiz.a"));
        ex_tx.addObjectFile(b.path("lib/libmbedtls.a"));
        ex_tx.addObjectFile(b.path("lib/libthrift.a"));
        ex_tx.addObjectFile(b.path("lib/libparquet.a"));
        ex_tx.addObjectFile(b.path("lib/libroaring_bitmap.a"));
        ex_tx.addObjectFile(b.path("lib/libsimsimd.a"));
        ex_tx.addObjectFile(b.path("lib/libyyjson.a"));
    } else {
        if (resolved_libdir) |ld| ex_tx.addLibraryPath(ld);
        if (resolved_libname) |ln| ex_tx.linkSystemLibrary(ln);
    }
    ex_tx.linkLibC();
    ex_tx.linkLibCpp();
    switch (os_tag) {
        .linux => {
            ex_tx.linkSystemLibrary("pthread");
            ex_tx.linkSystemLibrary("dl");
            ex_tx.linkSystemLibrary("m");
        },
        .macos => {
            ex_tx.linkFramework("Foundation");
            ex_tx.linkSystemLibrary("pthread");
            ex_tx.linkSystemLibrary("m");
        },
        .windows => {
            ex_tx.linkSystemLibrary("ws2_32");
            ex_tx.linkSystemLibrary("bcrypt");
        },
        else => {},
    }
    const run_tx = b.addRunArtifact(ex_tx);
    run_tx.step.dependOn(b.getInstallStep());
    if (!(std.mem.eql(u8, kuzu_provider, "local") and !local_use_shared)) {
        if (resolved_libdir) |ld| {
            if (os_tag == .macos) run_tx.setEnvironmentVariable("DYLD_LIBRARY_PATH", ld.getPath(b)) else if (os_tag == .linux) run_tx.setEnvironmentVariable("LD_LIBRARY_PATH", ld.getPath(b)) else if (os_tag == .windows) run_tx.setEnvironmentVariable("PATH", ld.getPath(b));
        }
    }
    const example_tx_step = b.step("example-transactions", "Build and run transactions example");
    example_tx_step.dependOn(&run_tx.step);

    // Examples: pool
    const ex_pool = b.addExecutable(.{
        .name = "zkuzu-pool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/pool.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (source_build_step) |sb| ex_pool.step.dependOn(&sb.step);
    ex_pool.root_module.addImport("zkuzu", zkuzu);
    if (resolved_include) |inc| ex_pool.addIncludePath(inc) else ex_pool.addIncludePath(lib_path);
    if (std.mem.eql(u8, kuzu_provider, "local") and !local_use_shared) {
        ex_pool.addObjectFile(b.path("lib/libkuzu.a"));
        ex_pool.addObjectFile(b.path("lib/libbrotlidec.a"));
        ex_pool.addObjectFile(b.path("lib/libbrotlienc.a"));
        ex_pool.addObjectFile(b.path("lib/libbrotlicommon.a"));
        ex_pool.addObjectFile(b.path("lib/libfastpfor.a"));
        ex_pool.addObjectFile(b.path("lib/libantlr4_runtime.a"));
        ex_pool.addObjectFile(b.path("lib/libantlr4_cypher.a"));
        ex_pool.addObjectFile(b.path("lib/libre2.a"));
        ex_pool.addObjectFile(b.path("lib/libutf8proc.a"));
        ex_pool.addObjectFile(b.path("lib/libzstd.a"));
        ex_pool.addObjectFile(b.path("lib/libsnappy.a"));
        ex_pool.addObjectFile(b.path("lib/liblz4.a"));
        ex_pool.addObjectFile(b.path("lib/libminiz.a"));
        ex_pool.addObjectFile(b.path("lib/libmbedtls.a"));
        ex_pool.addObjectFile(b.path("lib/libthrift.a"));
        ex_pool.addObjectFile(b.path("lib/libparquet.a"));
        ex_pool.addObjectFile(b.path("lib/libroaring_bitmap.a"));
        ex_pool.addObjectFile(b.path("lib/libsimsimd.a"));
        ex_pool.addObjectFile(b.path("lib/libyyjson.a"));
    } else {
        if (resolved_libdir) |ld| ex_pool.addLibraryPath(ld);
        if (resolved_libname) |ln| ex_pool.linkSystemLibrary(ln);
    }
    ex_pool.linkLibC();
    ex_pool.linkLibCpp();
    switch (os_tag) {
        .linux => {
            ex_pool.linkSystemLibrary("pthread");
            ex_pool.linkSystemLibrary("dl");
            ex_pool.linkSystemLibrary("m");
        },
        .macos => {
            ex_pool.linkFramework("Foundation");
            ex_pool.linkSystemLibrary("pthread");
            ex_pool.linkSystemLibrary("m");
        },
        .windows => {
            ex_pool.linkSystemLibrary("ws2_32");
            ex_pool.linkSystemLibrary("bcrypt");
        },
        else => {},
    }
    const run_pool = b.addRunArtifact(ex_pool);
    run_pool.step.dependOn(b.getInstallStep());
    if (!(std.mem.eql(u8, kuzu_provider, "local") and !local_use_shared)) {
        if (resolved_libdir) |ld| {
            if (os_tag == .macos) run_pool.setEnvironmentVariable("DYLD_LIBRARY_PATH", ld.getPath(b)) else if (os_tag == .linux) run_pool.setEnvironmentVariable("LD_LIBRARY_PATH", ld.getPath(b)) else if (os_tag == .windows) run_pool.setEnvironmentVariable("PATH", ld.getPath(b));
        }
    }
    const example_pool_step = b.step("example-pool", "Build and run pool example");
    example_pool_step.dependOn(&run_pool.step);

    // Examples: performance
    const ex_perf = b.addExecutable(.{
        .name = "zkuzu-performance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/performance.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (source_build_step) |sb| ex_perf.step.dependOn(&sb.step);
    ex_perf.root_module.addImport("zkuzu", zkuzu);
    if (resolved_include) |inc| ex_perf.addIncludePath(inc) else ex_perf.addIncludePath(lib_path);
    if (std.mem.eql(u8, kuzu_provider, "local") and !local_use_shared) {
        ex_perf.addObjectFile(b.path("lib/libkuzu.a"));
        ex_perf.addObjectFile(b.path("lib/libbrotlidec.a"));
        ex_perf.addObjectFile(b.path("lib/libbrotlienc.a"));
        ex_perf.addObjectFile(b.path("lib/libbrotlicommon.a"));
        ex_perf.addObjectFile(b.path("lib/libfastpfor.a"));
        ex_perf.addObjectFile(b.path("lib/libantlr4_runtime.a"));
        ex_perf.addObjectFile(b.path("lib/libantlr4_cypher.a"));
        ex_perf.addObjectFile(b.path("lib/libre2.a"));
        ex_perf.addObjectFile(b.path("lib/libutf8proc.a"));
        ex_perf.addObjectFile(b.path("lib/libzstd.a"));
        ex_perf.addObjectFile(b.path("lib/libsnappy.a"));
        ex_perf.addObjectFile(b.path("lib/liblz4.a"));
        ex_perf.addObjectFile(b.path("lib/libminiz.a"));
        ex_perf.addObjectFile(b.path("lib/libmbedtls.a"));
        ex_perf.addObjectFile(b.path("lib/libthrift.a"));
        ex_perf.addObjectFile(b.path("lib/libparquet.a"));
        ex_perf.addObjectFile(b.path("lib/libroaring_bitmap.a"));
        ex_perf.addObjectFile(b.path("lib/libsimsimd.a"));
        ex_perf.addObjectFile(b.path("lib/libyyjson.a"));
    } else {
        if (resolved_libdir) |ld| ex_perf.addLibraryPath(ld);
        if (resolved_libname) |ln| ex_perf.linkSystemLibrary(ln);
    }
    ex_perf.linkLibC();
    ex_perf.linkLibCpp();
    switch (os_tag) {
        .linux => {
            ex_perf.linkSystemLibrary("pthread");
            ex_perf.linkSystemLibrary("dl");
            ex_perf.linkSystemLibrary("m");
        },
        .macos => {
            ex_perf.linkFramework("Foundation");
            ex_perf.linkSystemLibrary("pthread");
            ex_perf.linkSystemLibrary("m");
        },
        .windows => {
            ex_perf.linkSystemLibrary("ws2_32");
            ex_perf.linkSystemLibrary("bcrypt");
        },
        else => {},
    }
    const run_perf = b.addRunArtifact(ex_perf);
    run_perf.step.dependOn(b.getInstallStep());
    if (!(std.mem.eql(u8, kuzu_provider, "local") and !local_use_shared)) {
        if (resolved_libdir) |ld| {
            if (os_tag == .macos) run_perf.setEnvironmentVariable("DYLD_LIBRARY_PATH", ld.getPath(b)) else if (os_tag == .linux) run_perf.setEnvironmentVariable("LD_LIBRARY_PATH", ld.getPath(b)) else if (os_tag == .windows) run_perf.setEnvironmentVariable("PATH", ld.getPath(b));
        }
    }
    const example_perf_step = b.step("example-performance", "Build and run performance example");
    example_perf_step.dependOn(&run_perf.step);

    // Examples: error handling
    const ex_err = b.addExecutable(.{
        .name = "zkuzu-errors",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/error_handling.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (source_build_step) |sb| ex_err.step.dependOn(&sb.step);
    ex_err.root_module.addImport("zkuzu", zkuzu);
    if (resolved_include) |inc| ex_err.addIncludePath(inc) else ex_err.addIncludePath(lib_path);
    if (std.mem.eql(u8, kuzu_provider, "local") and !local_use_shared) {
        ex_err.addObjectFile(b.path("lib/libkuzu.a"));
        ex_err.addObjectFile(b.path("lib/libbrotlidec.a"));
        ex_err.addObjectFile(b.path("lib/libbrotlienc.a"));
        ex_err.addObjectFile(b.path("lib/libbrotlicommon.a"));
        ex_err.addObjectFile(b.path("lib/libfastpfor.a"));
        ex_err.addObjectFile(b.path("lib/libantlr4_runtime.a"));
        ex_err.addObjectFile(b.path("lib/libantlr4_cypher.a"));
        ex_err.addObjectFile(b.path("lib/libre2.a"));
        ex_err.addObjectFile(b.path("lib/libutf8proc.a"));
        ex_err.addObjectFile(b.path("lib/libzstd.a"));
        ex_err.addObjectFile(b.path("lib/libsnappy.a"));
        ex_err.addObjectFile(b.path("lib/liblz4.a"));
        ex_err.addObjectFile(b.path("lib/libminiz.a"));
        ex_err.addObjectFile(b.path("lib/libmbedtls.a"));
        ex_err.addObjectFile(b.path("lib/libthrift.a"));
        ex_err.addObjectFile(b.path("lib/libparquet.a"));
        ex_err.addObjectFile(b.path("lib/libroaring_bitmap.a"));
        ex_err.addObjectFile(b.path("lib/libsimsimd.a"));
        ex_err.addObjectFile(b.path("lib/libyyjson.a"));
    } else {
        if (resolved_libdir) |ld| ex_err.addLibraryPath(ld);
        if (resolved_libname) |ln| ex_err.linkSystemLibrary(ln);
    }
    ex_err.linkLibC();
    ex_err.linkLibCpp();
    switch (os_tag) {
        .linux => {
            ex_err.linkSystemLibrary("pthread");
            ex_err.linkSystemLibrary("dl");
            ex_err.linkSystemLibrary("m");
        },
        .macos => {
            ex_err.linkFramework("Foundation");
            ex_err.linkSystemLibrary("pthread");
            ex_err.linkSystemLibrary("m");
        },
        .windows => {
            ex_err.linkSystemLibrary("ws2_32");
            ex_err.linkSystemLibrary("bcrypt");
        },
        else => {},
    }
    const run_err = b.addRunArtifact(ex_err);
    run_err.step.dependOn(b.getInstallStep());
    if (!(std.mem.eql(u8, kuzu_provider, "local") and !local_use_shared)) {
        if (resolved_libdir) |ld| {
            if (os_tag == .macos) run_err.setEnvironmentVariable("DYLD_LIBRARY_PATH", ld.getPath(b)) else if (os_tag == .linux) run_err.setEnvironmentVariable("LD_LIBRARY_PATH", ld.getPath(b)) else if (os_tag == .windows) run_err.setEnvironmentVariable("PATH", ld.getPath(b));
        }
    }
    const example_errors_step = b.step("example-errors", "Build and run error-handling example");
    example_errors_step.dependOn(&run_err.step);
}
