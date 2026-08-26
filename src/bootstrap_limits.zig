/// `--bootstrap-limits` / `--print-bootstrap`: what this BINARY delivers.
///
/// A consumer that composes a workspace for NullClaw has to know two things it
/// cannot read from outside the process: the compiled budget that decides how
/// much of that workspace reaches the model, and the injection order that
/// decides which part is dropped when the budget runs out. Until this module
/// existed a consumer could only restate those numbers by hand — and a hand
/// restatement is a belief, not a measurement. In August 2026 a raise of
/// `BOOTSTRAP_TOTAL_MAX_CHARS` from 24,000 to 32,000 sat in the source for five
/// days while the deployed binary still enforced 24,000; every test downstream
/// stayed green because all of them measured the restatement.
///
/// Both modes are deterministic: no network, no model, no config, no state.
/// They read the same constants and the same builder the agent loop uses, so
/// they cannot describe a binary other than the one being run.
const std = @import("std");
const std_compat = @import("compat");
const prompt = @import("agent/prompt.zig");

fn writeStringArray(out: *std.Io.Writer, values: []const []const u8) !void {
    try out.writeByte('[');
    for (values, 0..) |value, idx| {
        if (idx > 0) try out.writeByte(',');
        try out.print("{f}", .{std.json.fmt(value, .{})});
    }
    try out.writeByte(']');
}

/// Serialize the compiled limits. Separated from `run` so a test can assert on
/// the bytes without touching stdout.
pub fn writeLimitsJson(out: *std.Io.Writer) !void {
    const limits = prompt.bootstrapLimits();
    try out.writeAll("{\"schema_version\":1,\"bootstrapTotalMaxChars\":");
    try out.print("{d}", .{limits.bootstrap_total_max_chars});
    try out.writeAll(",\"bootstrapFileMaxChars\":");
    try out.print("{d}", .{limits.bootstrap_file_max_chars});
    try out.writeAll(",\"bootstrapProviderExcerptBytes\":");
    try out.print("{d}", .{limits.bootstrap_provider_excerpt_bytes});
    try out.writeAll(",\"maxWorkspaceBootstrapFileBytes\":");
    try out.print("{d}", .{limits.max_workspace_bootstrap_file_bytes});
    try out.writeAll(",\"identityFileOrder\":");
    try writeStringArray(out, limits.identity_file_order);
    try out.writeAll(",\"memoryFileOrder\":");
    try writeStringArray(out, limits.memory_file_order);
    try out.writeAll("}\n");
}

/// `nullclaw --bootstrap-limits`
pub fn run() !void {
    var buf: [4096]u8 = undefined;
    var bw = std_compat.fs.File.stdout().writer(&buf);
    const out = &bw.interface;
    try writeLimitsJson(out);
    try out.flush();
}

/// `nullclaw --print-bootstrap <workspace-dir>`
///
/// Prints the exact `## Project Context` block this binary would inject for
/// that directory, truncation markers and all. A consumer diffs its composed
/// bytes against this to learn what actually survives delivery.
pub fn runPrint(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("error: --print-bootstrap requires a workspace directory\n", .{});
        std_compat.process.exit(1);
    }

    const section = prompt.buildProjectContextSection(allocator, args[0]) catch |err| {
        std.debug.print("error: could not build project context for '{s}': {s}\n", .{ args[0], @errorName(err) });
        std_compat.process.exit(1);
    };
    defer allocator.free(section);

    var buf: [8192]u8 = undefined;
    var bw = std_compat.fs.File.stdout().writer(&buf);
    const out = &bw.interface;
    try out.writeAll(section);
    try out.flush();
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "writeLimitsJson reports the compiled caps and injection order" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    defer buf = writer.toArrayList();

    try writeLimitsJson(&writer.writer);

    const json = writer.written();
    // The numbers are the point: a consumer compares these against its own
    // restatement, so they must be the compiled values and not a literal.
    const limits = prompt.bootstrapLimits();
    var expected_total: [64]u8 = undefined;
    const total_needle = try std.fmt.bufPrint(
        &expected_total,
        "\"bootstrapTotalMaxChars\":{d}",
        .{limits.bootstrap_total_max_chars},
    );
    try std.testing.expect(std.mem.indexOf(u8, json, total_needle) != null);

    var expected_file: [64]u8 = undefined;
    const file_needle = try std.fmt.bufPrint(
        &expected_file,
        "\"bootstrapFileMaxChars\":{d}",
        .{limits.bootstrap_file_max_chars},
    );
    try std.testing.expect(std.mem.indexOf(u8, json, file_needle) != null);

    // Order, not just membership: AGENTS.md must precede TOOLS.md, because that
    // is what decides who is cut when the budget runs out.
    const agents_at = std.mem.indexOf(u8, json, "\"AGENTS.md\"").?;
    const tools_at = std.mem.indexOf(u8, json, "\"TOOLS.md\"").?;
    try std.testing.expect(agents_at < tools_at);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"memoryFileOrder\":[\"MEMORY.md\",\"memory.md\"]") != null);

    // It must parse.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(
        @as(i64, @intCast(limits.bootstrap_total_max_chars)),
        parsed.value.object.get("bootstrapTotalMaxChars").?.integer,
    );
}

test "bootstrapLimits injection order matches the identity files the prompt injects" {
    const limits = prompt.bootstrapLimits();
    try std.testing.expectEqual(@as(usize, 8), limits.identity_file_order.len);
    try std.testing.expectEqualStrings("AGENTS.md", limits.identity_file_order[0]);
    try std.testing.expectEqualStrings("TOOLS.md", limits.identity_file_order[2]);
    try std.testing.expect(limits.bootstrap_provider_excerpt_bytes > limits.bootstrap_file_max_chars);
    try std.testing.expect(limits.bootstrap_total_max_chars >= limits.bootstrap_file_max_chars);
}

test "buildProjectContextSection delivers in order and marks the total cut" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    const limits = prompt.bootstrapLimits();

    // AGENTS.md spends the whole PER-FILE cap, which is what production's
    // largest file does; what remains of the TOTAL is the difference between
    // the two caps. TOOLS.md is then written larger than that remainder with
    // its marker at the very end, so the marker survives only if the total
    // budget reaches it. Both caps are read from the binary, never typed.
    const agents = try std.testing.allocator.alloc(u8, limits.bootstrap_file_max_chars);
    defer std.testing.allocator.free(agents);
    @memset(agents, 'a');
    try std_compat.fs.Dir.wrap(tmp.dir).writeFile(.{ .sub_path = "AGENTS.md", .data = agents });

    const remainder = limits.bootstrap_total_max_chars - limits.bootstrap_file_max_chars;
    const marker = "## Reply format survives-or-not\n";
    const tools = try std.testing.allocator.alloc(u8, remainder + 1_000 + marker.len);
    defer std.testing.allocator.free(tools);
    @memset(tools, 't');
    @memcpy(tools[tools.len - marker.len ..], marker);
    try std_compat.fs.Dir.wrap(tmp.dir).writeFile(.{ .sub_path = "TOOLS.md", .data = tools });

    const section = try prompt.buildProjectContextSection(std.testing.allocator, dir_path);
    defer std.testing.allocator.free(section);

    try std.testing.expect(std.mem.indexOf(u8, section, "### AGENTS.md") != null);
    // The budget ran out inside TOOLS.md, so the binary says so in its own words.
    try std.testing.expect(std.mem.indexOf(u8, section, "stopped at project context budget") != null);
    try std.testing.expect(std.mem.indexOf(u8, section, "survives-or-not") == null);
}

test "buildProjectContextSection delivers a workspace that fits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    try std_compat.fs.Dir.wrap(tmp.dir).writeFile(.{ .sub_path = "AGENTS.md", .data = "core contract\n" });
    try std_compat.fs.Dir.wrap(tmp.dir).writeFile(.{ .sub_path = "TOOLS.md", .data = "## Reply format\nplain sentences\n" });
    try std_compat.fs.Dir.wrap(tmp.dir).writeFile(.{ .sub_path = "MEMORY.md", .data = "tenant facts\n" });

    const section = try prompt.buildProjectContextSection(std.testing.allocator, dir_path);
    defer std.testing.allocator.free(section);

    try std.testing.expect(std.mem.indexOf(u8, section, "core contract") != null);
    try std.testing.expect(std.mem.indexOf(u8, section, "## Reply format") != null);
    try std.testing.expect(std.mem.indexOf(u8, section, "tenant facts") != null);
    try std.testing.expect(std.mem.indexOf(u8, section, "stopped at project context budget") == null);
}
