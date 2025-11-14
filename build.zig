const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const resolved = b.standardTargetOptions(.{});
    const tgt = resolved.result;
    const host = builtin.target;
    const optimize = b.standardOptimizeOption(.{});

    const zlib_dep = b.dependency("zlib", .{
        .target = resolved,
        .optimize = optimize,
    });
    const zlib = zlib_dep.artifact("z");
    zlib.want_lto = true; // Enable LTO
    zlib.root_module.link_libc = true;

    const libpng_dep = b.dependency("libpng", .{});
    const png = b.addLibrary(.{
        .name = "png",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = resolved,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    png.want_lto = true; // Enable LTO
    png.addIncludePath(libpng_dep.path(""));
    if (tgt.os.tag == .linux) {
        png.root_module.linkSystemLibrary("m", .{});
    }
    png.root_module.linkLibrary(zlib);

    // Copy pnglibconf.h.prebuilt to pnglibconf.h
    const wf = b.addWriteFiles();
    const pnglibconf_h = wf.addCopyFile(libpng_dep.path("pnglibconf.h.prebuilt"), "pnglibconf.h");
    png.addIncludePath(wf.getDirectory());
    png.step.dependOn(&wf.step);
    
    inline for (pngSources) |source| {
        png.addCSourceFile(.{ .file = libpng_dep.path(source) });
    }

    png.installHeader(pnglibconf_h, "pnglibconf.h");
    inline for (pngHeaders) |header| {
        png.installHeader(libpng_dep.path(header), header);
    }
    b.installArtifact(png);

    // mimalloc - high performance allocator
    const mimalloc_dep = b.dependency("mimalloc", .{});
    const mimalloc = b.addLibrary(.{
        .name = "mimalloc",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = resolved,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    mimalloc.want_lto = true; // Enable LTO
    mimalloc.addIncludePath(mimalloc_dep.path("include"));
    
    // Add mimalloc source - use static.c which includes all other files
    const mimalloc_flags = &.{"-DMI_MALLOC_OVERRIDE"};
    mimalloc.addCSourceFile(.{ .file = mimalloc_dep.path("src/static.c"), .flags = mimalloc_flags });
    
    // Install headers so we can include mimalloc-override.h
    mimalloc.installHeadersDirectory(mimalloc_dep.path("include"), "", .{});
    b.installArtifact(mimalloc);

    const include_root = "include";
    const src_root = "src";

    const rust_crate_dir = "astonia_net";
    const rust_target = rustTripleFor(tgt);

    const rustup = b.addSystemCommand(&.{ "rustup", "target", "add", rust_target });
    const cargo = b.addSystemCommand(&.{
        "cargo",           "build",                                        "--release",
        "--manifest-path", b.pathJoin(&.{ rust_crate_dir, "Cargo.toml" }), "--target",
        rust_target,
    });
    cargo.step.dependOn(&rustup.step);

    const rust_out_dir = b.pathJoin(&.{ rust_crate_dir, "target", rust_target, "release" });
    
    // Linux uses static library, Windows uses dynamic
    const rust_lib_name = switch (tgt.os.tag) {
        .windows => "astonia_net.dll",
        .linux => "libastonia_net.a",
        else => "libastonia_net.a",
    };
    const rust_lib_path = b.pathJoin(&.{ rust_out_dir, rust_lib_name });

    const common_sources = &.{
        // GUI
        "src/gui/gui.c",
        "src/gui/dots.c",
        "src/gui/display.c",
        "src/gui/teleport.c",
        "src/gui/color.c",
        "src/gui/cmd.c",
        "src/gui/questlog.c",
        "src/gui/context.c",
        "src/gui/hover.c",
        "src/gui/minimap.c",

        // CLIENT
        "src/client/client.c",
        "src/client/skill.c",

        // GAME
        "src/game/dd.c",
        "src/game/font.c",
        "src/game/game.c",
        "src/game/main.c",
        "src/game/sprite.c",

        // MODDER core
        "src/modder/modder.c",

        // SDL layer
        "src/sdl/sound.c",
        "src/sdl/sdl.c",

        // HELPERS
        "src/helper/helper.c",
    };

    const win_sources = &.{
        "src/modder/sharedmem_windows.c",
        "src/game/crash_handler_windows.c",
        "src/game/memory_windows.c",
        "src/gui/draghack_windows.c",
        "src/client/unique_windows.c",
    };

    const linux_sources = &.{
        "src/game/memory_linux.c",
    };

    // Get mimalloc override header path for -include flag
    const mimalloc_override_path = b.pathJoin(&.{
        mimalloc_dep.path("include").getPath(b),
        "mimalloc-override.h",
    });

    const base_cflags = &.{
        "-O3",
        "-gdwarf-4",
        "-Wall",
        "-Wno-pointer-sign",
        "-Wno-char-subscripts",
        "-fno-omit-frame-pointer",
        "-fvisibility=hidden",
        "-include",
        mimalloc_override_path,
    };

    const win_cflags = &.{
        "-O3",
        "-gdwarf-4",
        "-Wall",
        "-Wno-pointer-sign",
        "-Wno-char-subscripts",
        "-fno-omit-frame-pointer",
        "-fvisibility=hidden",
        "-Dmain=SDL_main",
        "-DSTORE_UNIQUE",
        "-DENABLE_CRASH_HANDLER",
        "-DENABLE_SHAREDMEM",
        "-DENABLE_DRAGHACK",
        "-include",
        mimalloc_override_path,
    };

    const exe = b.addExecutable(.{
        .name = "moac",
        .root_module = b.createModule(.{
            .target = resolved,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.want_lto = true; // Enable LTO for whole program optimization

    addSearchPathsForWindowsTarget(b, exe, tgt, host);

    if (tgt.os.tag == .windows) {
        exe.addCSourceFiles(.{ .files = common_sources, .flags = win_cflags });
        exe.addCSourceFiles(.{ .files = win_sources, .flags = win_cflags });
    } else {
        exe.addCSourceFiles(.{ .files = common_sources, .flags = base_cflags });
    }

    if (tgt.os.tag == .linux) {
        exe.addCSourceFiles(.{
            .files = linux_sources,
            .flags = &.{
                "-O3",                     "-gdwarf-4",            "-Wall",
                "-Wno-pointer-sign",       "-Wno-char-subscripts", "-fPIC",
                "-fno-omit-frame-pointer", "-fvisibility=hidden",
            },
        });
    }

    // Allow __DATE__/__TIME__ (warning rather than error)
    if (tgt.os.tag == .windows) {
        exe.addCSourceFile(.{ .file = b.path("src/game/version.c"), .flags = &.{ "-Wno-error=date-time", "-Dmain=SDL_main", "-DSTORE_UNIQUE", "-DENABLE_CRASH_HANDLER", "-DENABLE_SHAREDMEM", "-DENABLE_DRAGHACK" } });
    } else {
        exe.addCSourceFile(.{ .file = b.path("src/game/version.c"), .flags = &.{"-Wno-error=date-time"} });
    }

    exe.root_module.addIncludePath(b.path(include_root));
    exe.root_module.addIncludePath(b.path(src_root));
    
    // Add mimalloc include path and link it
    exe.root_module.addIncludePath(mimalloc_dep.path("include"));
    exe.root_module.linkLibrary(mimalloc);

    // Link libs (Makefile equivalent: -lwsock32 -lws2_32 -lz -lpng -lzip -ldwarfstack $(SDL_LIBS) -lSDL2_mixer)
    linkCommonLibs(b, exe, tgt, zlib, png);

    exe.step.dependOn(&cargo.step);

    if (tgt.os.tag == .linux) {
        // Link static Rust library
        exe.addObjectFile(b.path(rust_lib_path));
        
        // Link system libraries required by Rust
        exe.root_module.linkSystemLibrary("pthread", .{});
        exe.root_module.linkSystemLibrary("dl", .{});
        exe.root_module.linkSystemLibrary("m", .{});
        exe.root_module.linkSystemLibrary("gcc_s", .{});
    } else if (tgt.os.tag == .windows) {
    exe.addLibraryPath(b.path(rust_out_dir));
    exe.linkSystemLibrary("astonia_net");
    }

    if (tgt.os.tag == .windows) {
        const res = b.pathJoin(&.{ "src", "game", "resource.o" });
        const windres = b.addSystemCommand(&.{ "windres", "-F", "pe-x86-64", "src/game/resource.rc", res });
        exe.step.dependOn(&windres.step);
        exe.addObjectFile(b.path(res));
        exe.subsystem = .Windows;
        exe.generated_implib = b.allocator.create(std.Build.GeneratedFile) catch unreachable;
        exe.generated_implib.?.* = .{
            .step = &exe.step,
            .path = null,
        };
    }

    b.installArtifact(exe);

    var exe_implib_install: ?*std.Build.Step.InstallFile = null;
    if (tgt.os.tag == .windows) {
        exe_implib_install = b.addInstallFileWithDir(.{ .generated = .{ .file = exe.generated_implib.? } }, .lib, "moac.lib");
        exe_implib_install.?.step.dependOn(&exe.step);
        b.getInstallStep().dependOn(&exe_implib_install.?.step);
    }

    // Only install dynamic library for Windows (Linux uses static linking)
    if (tgt.os.tag == .windows) {
        const install_rust_lib = b.addInstallFileWithDir(b.path(rust_lib_path), .bin, rust_lib_name);
        install_rust_lib.step.dependOn(&cargo.step);
        b.getInstallStep().dependOn(&install_rust_lib.step);
    }

    const amod = b.addLibrary(.{
        .name = "amod",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .target = resolved,
            .optimize = optimize,
            .link_libc = true,
        }),
        .version = .{ .major = 0, .minor = 0, .patch = 0 },
    });
    amod.want_lto = true; // Enable LTO

    if (tgt.os.tag == .linux) {
        amod.linker_allow_shlib_undefined = true;
    }

    if (tgt.os.tag == .windows) {
        amod.addCSourceFile(.{ .file = b.path("src/amod/amod.c"), .flags = win_cflags });
    } else {
        amod.addCSourceFile(.{ .file = b.path("src/amod/amod.c"), .flags = &.{ "-O3", "-gdwarf-4", "-Wall" } });
    }
    amod.root_module.addIncludePath(b.path(include_root));
    amod.root_module.addIncludePath(b.path(src_root));
    addSearchPathsForWindowsTarget(b, amod, tgt, host);
    linkCommonLibs(b, amod, tgt, zlib, png);

    if (tgt.os.tag == .windows) {
        amod.addObjectFile(.{ .generated = .{ .file = exe.generated_implib.? } });
        amod.step.dependOn(&exe.step);
    }

    b.installArtifact(amod);

    const anicopy = b.addExecutable(.{
        .name = "anicopy",
        .root_module = b.createModule(.{ .target = resolved, .optimize = optimize, .link_libc = true }),
    });
    anicopy.want_lto = true; // Enable LTO
    anicopy.addCSourceFile(.{ .file = b.path("src/helper/anicopy.c"), .flags = &.{ "-O3", "-gdwarf-4", "-Wall" } });
    anicopy.root_module.addIncludePath(b.path(include_root));
    anicopy.root_module.addIncludePath(b.path(src_root));
    addSearchPathsForWindowsTarget(b, anicopy, tgt, host);
    b.installArtifact(anicopy);

    const convert = b.addExecutable(.{
        .name = "convert",
        .root_module = b.createModule(.{ .target = resolved, .optimize = optimize, .link_libc = true }),
    });
    convert.want_lto = true; // Enable LTO
    convert.addCSourceFile(.{ .file = b.path("src/helper/convert.c"), .flags = &.{ "-O3", "-gdwarf-4", "-Wall", "-DSTANDALONE" } });
    convert.root_module.addIncludePath(b.path(include_root));
    convert.root_module.addIncludePath(b.path(src_root));
    addSearchPathsForWindowsTarget(b, convert, tgt, host);

    if (tgt.os.tag == .windows) {
        linkSystemLibraryPreferDynamic(b, convert, "png", tgt);
        linkSystemLibraryPreferDynamic(b, convert, "zip", tgt);
        linkSystemLibraryPreferDynamic(b, convert, "z", tgt);
    } else if (tgt.os.tag == .linux) {
        convert.root_module.linkLibrary(png);
        convert.root_module.linkSystemLibrary("zip", .{});
        convert.root_module.linkSystemLibrary("m", .{});
    }
    b.installArtifact(convert);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run moac").dependOn(&run.step);
}

fn linkCommonLibs(b: *std.Build, step: *std.Build.Step.Compile, tgt: std.Target, zlib: *std.Build.Step.Compile, png: *std.Build.Step.Compile) void {
    // Unified library linking for both platforms
    // Link our statically-built libraries with LTO enabled
    step.root_module.linkLibrary(zlib);
    step.root_module.linkLibrary(png);
    
    // Platform-specific system libraries
    if (tgt.os.tag == .windows) {
        // Windows-specific libraries
        step.root_module.linkSystemLibrary("wsock32", .{});
        step.root_module.linkSystemLibrary("ws2_32", .{});
        step.root_module.linkSystemLibrary("mingw32", .{});
        step.root_module.linkSystemLibrary("SDL2main", .{});
        
        // Libraries that still need system versions
        linkSystemLibraryPreferDynamic(b, step, "zip", tgt);
        linkSystemLibraryPreferDynamic(b, step, "dwarfstack", tgt);
        linkSystemLibraryPreferDynamic(b, step, "SDL2", tgt);
        linkSystemLibraryPreferDynamic(b, step, "SDL2_mixer", tgt);
    } else if (tgt.os.tag == .linux) {
        // Linux-specific libraries
        step.root_module.linkSystemLibrary("zip", .{});
        step.root_module.linkSystemLibrary("SDL2", .{});
        step.root_module.linkSystemLibrary("SDL2_mixer", .{});
        step.root_module.linkSystemLibrary("m", .{});
    }
}

/// Find a library file, preferring dynamic versions over static ones.
/// Searches through directories specified in LIBRARY_PATH environment variable,
/// or falls back to default system paths.
///
/// For Windows: prefers libX.dll.a over libX.a
/// For Linux: prefers libX.so over libX.a
fn findSystemLibrary(
    b: *std.Build,
    lib_name: []const u8,
    target: std.Target,
) ![]const u8 {
    const gpa = b.allocator;

    const extensions = if (target.os.tag == .windows)
        &[_][]const u8{ ".dll.a", ".a" }
    else
        &[_][]const u8{ ".so", ".a" };

    const search_paths = blk: {
        if (b.graph.env_map.get("LIBRARY_PATH")) |lib_path| {
            const separator: u8 = if (target.os.tag == .windows) ';' else ':';
            var path_count: usize = 1;
            for (lib_path) |c| {
                if (c == separator) path_count += 1;
            }

            const paths = try gpa.alloc([]const u8, path_count);
            var it = std.mem.splitScalar(u8, lib_path, separator);
            var idx: usize = 0;
            while (it.next()) |path| {
                if (idx < path_count) {
                    paths[idx] = path;
                    idx += 1;
                }
            }
            break :blk paths;
        }

        // Fall back to platform-specific defaults
        if (target.os.tag == .windows) {
            // Windows defaults - only clang64 to avoid ABI mismatches
            // (Zig uses clang internally, so we need clang-compiled libraries)
            const defaults = &[_][]const u8{
                "C:\\msys64\\clang64\\lib",
            };
            break :blk try gpa.dupe([]const u8, defaults);
        } else {
            // This shouldn't be reached on Linux since we use linkSystemLibrary there,
            // but keep defaults just in case
            const defaults = &[_][]const u8{
                "/usr/lib",
                "/usr/local/lib",
                "/usr/lib/x86_64-linux-gnu",
            };
            break :blk try gpa.dupe([]const u8, defaults);
        }
    };
    defer gpa.free(search_paths);

    const lib_filename_base = try std.fmt.allocPrint(gpa, "lib{s}", .{lib_name});
    defer gpa.free(lib_filename_base);

    for (search_paths) |search_path| {
        for (extensions) |ext| {
            const filename = try std.fmt.allocPrint(gpa, "{s}{s}", .{ lib_filename_base, ext });
            defer gpa.free(filename);

            const full_path = try std.fs.path.join(gpa, &.{ search_path, filename });

            std.fs.accessAbsolute(full_path, .{}) catch {
                gpa.free(full_path);
                continue;
            };

            return full_path;
        }
    }

    // Not found in any search path
    return error.LibraryNotFound;
}

/// Link a system library, preferring dynamic versions.
/// Uses findSystemLibrary to locate the library file.
fn linkSystemLibraryPreferDynamic(
    b: *std.Build,
    step: *std.Build.Step.Compile,
    lib_name: []const u8,
    target: std.Target,
) void {
    const lib_path = findSystemLibrary(b, lib_name, target) catch |err| {
        std.debug.print("Warning: Could not find library '{s}': {s}\n", .{ lib_name, @errorName(err) });
        std.debug.print("Falling back to standard linkSystemLibrary\n", .{});
        step.linkSystemLibrary(lib_name);
        return;
    };

    step.addObjectFile(.{ .cwd_relative = lib_path });
}

fn rustTripleFor(t: std.Target) []const u8 {
    return switch (t.cpu.arch) {
        .x86_64 => switch (t.os.tag) {
            .linux => "x86_64-unknown-linux-gnu",
            .windows => "x86_64-pc-windows-gnu",
            else => @panic("unsupported OS for x86_64"),
        },
        else => @panic("unsupported arch"),
    };
}

fn addSearchPathsForWindowsTarget(
    b: *std.Build,
    a: *std.Build.Step.Compile,
    target: std.Target,
    host_target: std.Target,
) void {
    if (target.os.tag != .windows) return;

    const gpa = b.allocator;

    if (host_target.os.tag == .windows) {
        // Building on Windows for Windows - use explicit clang64 paths
        const clang64_root = "C:\\msys64\\clang64";

        const inc = std.fs.path.join(gpa, &.{ clang64_root, "include" }) catch unreachable;
        const inc_sdl2 = std.fs.path.join(gpa, &.{ clang64_root, "include", "SDL2" }) catch unreachable;
        const inc_png = std.fs.path.join(gpa, &.{ clang64_root, "include", "libpng16" }) catch unreachable;
        const lib = std.fs.path.join(gpa, &.{ clang64_root, "lib" }) catch unreachable;

        a.root_module.addIncludePath(.{ .cwd_relative = inc });
        a.root_module.addIncludePath(.{ .cwd_relative = inc_sdl2 });
        a.root_module.addIncludePath(.{ .cwd_relative = inc_png });
        a.addLibraryPath(.{ .cwd_relative = lib });
    } else if (host_target.os.tag == .linux) {
        // Cross-compiling from Linux to Windows
        const clang_prefix = "/clang64";

        const incl = std.fs.path.join(gpa, &.{ clang_prefix, "include" }) catch unreachable;
        const lib = std.fs.path.join(gpa, &.{ clang_prefix, "lib" }) catch unreachable;

        a.root_module.addIncludePath(.{ .cwd_relative = incl });
        a.addLibraryPath(.{ .cwd_relative = lib });
    }
}

const pngSources = &.{
    "png.c",
    "pngerror.c",
    "pngget.c",
    "pngmem.c",
    "pngpread.c",
    "pngread.c",
    "pngrio.c",
    "pngrtran.c",
    "pngrutil.c",
    "pngset.c",
    "pngsimd.c",
    "pngtrans.c",
    "pngwio.c",
    "pngwrite.c",
    "pngwtran.c",
    "pngwutil.c",
};

const pngHeaders = &.{
    "png.h",
    "pngconf.h",
    "pngdebug.h",
    "pnginfo.h",
    "pngpriv.h",
    "pngstruct.h",
};
