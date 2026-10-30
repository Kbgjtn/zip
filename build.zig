const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("zip", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
        .optimize = optimize,
    });

    // `zig build test -Dslow-tests -Doptimize=ReleaseSafe` also runs the tests that stream
    // gigabytes (4.1 GiB through deflate, inflate and CRC-32). Debug works but takes about
    // 5.5 min.
    const build_options = b.addOptions();
    const slow_tests = b.option(
        bool,
        "slow-tests",
        "Also run tests that stream gigabytes (ZIP64 past 4 GiB); use with -Doptimize=ReleaseSafe",
    ) orelse false;
    build_options.addOption(bool, "slow_tests", slow_tests);
    mod.addOptions("build_options", build_options);

    const gen_testdata = b.addSystemCommand(&.{"python3"});
    gen_testdata.addFileArg(b.path("scripts/gen-testdata.py"));

    const gen_step = b.step("gen-testdata", "Generate test data");
    gen_step.dependOn(&gen_testdata.step);

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    // `zig build test -Dcoverage`: see run_mod_tests below.
    const coverage = b.option(bool, "coverage", "Run library tests under kcov; report in kcov-out/") orelse false;
    // `zig build test -Dtest-filter=<text>` builds only the tests whose names contain <text>,
    // e.g. to fuzz one target: `zig build test --fuzz -Dtest-filter="fuzz writer"`.
    const test_filters = b.option([]const []const u8, "test-filter", "Only build tests whose names contain this text (repeatable)") orelse &.{};
    // `zig build test --fuzz -Dllvm`: the self-hosted x86_64 backend emits no coverage
    // instrumentation, so 0.16.0's fuzzer has nothing to steer by and the build runner's
    // coverage task panics on the empty PC list. Fuzz with LLVM.
    const llvm = b.option(bool, "llvm", "Build the library tests with LLVM (needed for --fuzz)") orelse false;
    const mod_tests = b.addTest(.{
        .root_module = mod,
        .filters = test_filters,
        // kcov finds no src/ lines in the self-hosted backend's debug info, so coverage
        // builds use LLVM.
        .use_llvm = if (coverage or llvm) true else null,
        // Zig 0.16.0's stock runner breaks --fuzz; see tools/test_runner.zig.
        .test_runner = .{ .path = b.path("tools/test_runner.zig"), .mode = .server },
    });

    // A run step that will run the test executable.
    // With -Dcoverage it runs under kcov instead (needs `kcov` on PATH) and writes
    // an HTML line-coverage report for src/ to kcov-out/index.html.
    const run_mod_tests = if (coverage) cov: {
        const run = b.addSystemCommand(&.{
            "kcov",
            b.fmt("--include-path={s}", .{b.pathFromRoot("src")}),
            b.pathFromRoot("kcov-out"),
        });
        run.addArtifactArg(mod_tests);
        run.has_side_effects = true; // always rerun so the report is current
        break :cov run;
    } else b.addRunArtifact(mod_tests);

    // `zig build interop`: writer output through unzip, 7z, Python, zipinfo and std.zip. Kept
    // out of `zig build test` since it needs those tools; missing ones are skipped. A test
    // executable, so the writer's test-only `force_zip64` is there.
    const interop_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/interop.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zip", .module = mod },
            },
        }),
    });
    const run_interop = b.addRunArtifact(interop_tests);
    run_interop.has_side_effects = true; // the tools may change; always rerun
    const interop_step = b.step("interop", "Check writer output with unzip, 7z, Python, zipinfo and std.zip");
    interop_step.dependOn(&run_interop.step);

    // `zig build bench`: times writing and reading through the public API, see
    // tools/bench.zig. Built ReleaseFast unless -Doptimize names a release mode, with its
    // own copy of the module so the library is optimized too. Not part of `zig build test`.
    // Arguments go after `--`, e.g. `zig build bench -- --count 1000 --runs 3`.
    const bench_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseFast else optimize;
    const bench_zip = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    bench_zip.addOptions("build_options", build_options);
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench.zig"),
            .target = target,
            .optimize = bench_optimize,
            .imports = &.{
                .{ .name = "zip", .module = bench_zip },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.has_side_effects = true; // a benchmark always runs
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Time writing and reading archives (ReleaseFast)");
    bench_step.dependOn(&run_bench.step);

    // The README examples, built the way a user builds them: their own module that imports
    // "zip". The last test compares README.md's ```zig blocks with the file, which it
    // reads at run time, so README.md is an input of the run.
    const readme_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/readme.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zip", .module = mod },
            },
        }),
    });
    const run_readme_tests = b.addRunArtifact(readme_tests);
    run_readme_tests.addFileInput(b.path("README.md"));

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the run steps do not depend on one another, this will
    // make them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_readme_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
