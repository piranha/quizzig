const std = @import("std");
const build_options = @import("build_options");
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const Allocator = std.mem.Allocator;

// PCRE2 bindings
const pcre2 = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});

pub const version = build_options.version;

// Line types in a .t file
pub const LineType = enum {
    comment, // Non-indented line (or empty)
    command, // "  $ cmd"
    continuation, // "  > more"
    output, // "  expected output"
};

pub const Matcher = enum {
    literal,
    regex,
    glob,
    escape,
};

pub const ExpectedLine = struct {
    text: []const u8, // Pattern text with annotation stripped
    original: []const u8, // Original line for literal fallback
    matcher: Matcher,
    no_eol: bool,
};

pub const TestCommand = struct {
    lines: std.ArrayListUnmanaged([]const u8),
    expected: std.ArrayListUnmanaged(ExpectedLine),
    line_num: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator) TestCommand {
        return .{
            .lines = .{},
            .expected = .{},
            .line_num = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TestCommand) void {
        self.lines.deinit(self.allocator);
        self.expected.deinit(self.allocator);
    }

    pub fn appendLine(self: *TestCommand, line: []const u8) !void {
        try self.lines.append(self.allocator, line);
    }

    pub fn appendExpected(self: *TestCommand, exp: ExpectedLine) !void {
        try self.expected.append(self.allocator, exp);
    }
};

pub const CommandResult = struct {
    output: []const u8,
    exit_code: u8,
};

// Parser for .t files
pub const Parser = struct {
    allocator: Allocator,
    indent: usize,
    content: []const u8,
    lines: std.ArrayListUnmanaged([]const u8),

    pub fn init(allocator: Allocator, content: []const u8, indent: usize) !Parser {
        var lines: std.ArrayListUnmanaged([]const u8) = .{};
        var iter = mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            try lines.append(allocator, line);
        }
        return .{
            .allocator = allocator,
            .indent = indent,
            .content = content,
            .lines = lines,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.lines.deinit(self.allocator);
    }

    fn lineType(self: *const Parser, line: []const u8) LineType {
        if (line.len < self.indent) return .comment;
        const prefix = line[0..self.indent];
        for (prefix) |c| {
            if (c != ' ') return .comment;
        }
        const rest = line[self.indent..];
        if (rest.len >= 2 and rest[0] == '$' and rest[1] == ' ') return .command;
        if (rest.len >= 2 and rest[0] == '>' and rest[1] == ' ') return .continuation;
        if (rest.len >= 1 and rest[0] == '$' and rest.len == 1) return .command;
        if (rest.len >= 1 and rest[0] == '>' and rest.len == 1) return .continuation;
        return .output;
    }

    fn parseExpectedLine(_: *const Parser, line: []const u8) ExpectedLine {
        var text = line;
        var matcher = Matcher.literal;
        var no_eol = false;

        // Check for (no-eol) first (can combine with other annotations)
        if (mem.endsWith(u8, text, " (no-eol)")) {
            no_eol = true;
            text = text[0 .. text.len - 9];
        }

        // Check for matcher annotations at end
        if (mem.endsWith(u8, text, " (re)")) {
            matcher = .regex;
            text = text[0 .. text.len - 5];
        } else if (mem.endsWith(u8, text, " (glob)")) {
            matcher = .glob;
            text = text[0 .. text.len - 7];
        } else if (mem.endsWith(u8, text, " (esc)")) {
            matcher = .escape;
            text = text[0 .. text.len - 6];
        }

        return .{
            .text = text,
            .original = line, // Keep original for literal fallback
            .matcher = matcher,
            .no_eol = no_eol,
        };
    }

    pub fn parse(self: *Parser) !std.ArrayListUnmanaged(TestCommand) {
        var commands: std.ArrayListUnmanaged(TestCommand) = .{};
        var current_cmd: ?TestCommand = null;

        for (self.lines.items, 0..) |line, line_num| {
            const ltype = self.lineType(line);

            switch (ltype) {
                .command => {
                    // Save previous command if exists
                    if (current_cmd) |cmd| {
                        try commands.append(self.allocator, cmd);
                    }
                    current_cmd = TestCommand.init(self.allocator);
                    current_cmd.?.line_num = line_num + 1;
                    const cmd_text = if (line.len > self.indent + 2)
                        line[self.indent + 2 ..]
                    else
                        "";
                    try current_cmd.?.appendLine(cmd_text);
                },
                .continuation => {
                    if (current_cmd) |*cmd| {
                        const cont_text = if (line.len > self.indent + 2)
                            line[self.indent + 2 ..]
                        else
                            "";
                        try cmd.appendLine(cont_text);
                    }
                },
                .output => {
                    if (current_cmd) |*cmd| {
                        const out_text = line[self.indent..];
                        const expected = self.parseExpectedLine(out_text);
                        try cmd.appendExpected(expected);
                    }
                },
                .comment => {
                    // Save previous command if exists
                    if (current_cmd) |cmd| {
                        try commands.append(self.allocator, cmd);
                        current_cmd = null;
                    }
                },
            }
        }

        // Don't forget the last command
        if (current_cmd) |cmd| {
            try commands.append(self.allocator, cmd);
        }

        return commands;
    }
};

// Shell executor
pub const Executor = struct {
    allocator: Allocator,
    shell: []const u8,
    env: std.process.EnvMap,
    tmpdir: []const u8,

    pub fn init(allocator: Allocator, shell: []const u8, tmpdir: []const u8, opts: *const Options) !Executor {
        var env = std.process.EnvMap.init(allocator);

        // Start with inherited env or clean slate
        if (opts.inherit_env) {
            var parent_env = std.process.getEnvMap(allocator) catch std.process.EnvMap.init(allocator);
            defer parent_env.deinit();
            var it = parent_env.iterator();
            while (it.next()) |entry| {
                try env.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        // Set up normalized environment (overrides inherited)
        try env.put("LANG", "C");
        try env.put("LC_ALL", "C");
        try env.put("LANGUAGE", "C");
        try env.put("TZ", "GMT");
        try env.put("CDPATH", "");
        try env.put("COLUMNS", "80");
        try env.put("GREP_OPTIONS", "");
        try env.put("TMPDIR", tmpdir);
        try env.put("TEMP", tmpdir);
        try env.put("TMP", tmpdir);
        try env.put("HOME", tmpdir);
        try env.put("QUIZZIG", "1");

        // Build PATH: bindirs (reversed) + base path
        const base_path = if (opts.inherit_env)
            env.get("PATH") orelse "/usr/local/bin:/usr/bin:/bin"
        else
            "/usr/local/bin:/usr/bin:/bin";

        if (opts.bindirs.len > 0) {
            var path_parts: std.ArrayListUnmanaged(u8) = .{};
            defer path_parts.deinit(allocator);

            // Prepend bindirs in reverse order (last flag = first in PATH)
            var i: usize = opts.bindirs.len;
            while (i > 0) {
                i -= 1;
                try path_parts.appendSlice(allocator, opts.bindirs[i]);
                try path_parts.append(allocator, ':');
            }
            try path_parts.appendSlice(allocator, base_path);

            // EnvMap.put dupes the value internally
            try env.put("PATH", path_parts.items);
        } else {
            try env.put("PATH", base_path);
        }

        // Apply custom env vars (--env takes precedence)
        for (opts.env_vars) |ev| {
            try env.put(ev.key, ev.value);
        }

        return .{
            .allocator = allocator,
            .shell = shell,
            .env = env,
            .tmpdir = tmpdir,
        };
    }

    pub fn deinit(self: *Executor) void {
        self.env.deinit();
    }

    pub fn setTestEnv(self: *Executor, testdir: []const u8, testfile: []const u8, rootdir: []const u8) !void {
        try self.env.put("TESTDIR", testdir);
        try self.env.put("TESTFILE", testfile);
        try self.env.put("TESTSHELL", self.shell);
        try self.env.put("CRAMTMP", self.tmpdir);
        try self.env.put("ROOTDIR", rootdir);
    }

    pub fn execute(self: *Executor, commands: []const TestCommand, debug: bool) !std.ArrayListUnmanaged(CommandResult) {
        var results: std.ArrayListUnmanaged(CommandResult) = .{};

        // Generate unique salt to avoid collisions with nested quizzig runs
        var salt_buf: [32]u8 = undefined;
        const salt = try std.fmt.bufPrint(&salt_buf, "QUIZZIG{x}", .{std.crypto.random.int(u64)});

        // Build script with salt markers
        var script: std.ArrayListUnmanaged(u8) = .{};
        defer script.deinit(self.allocator);

        for (commands, 0..) |cmd, i| {
            // Write command
            for (cmd.lines.items) |line| {
                try script.appendSlice(self.allocator, line);
                try script.append(self.allocator, '\n');
            }
            // Write salt marker - capture exit code first, then output marker
            if (!debug) {
                try script.writer(self.allocator).print("__qz_ec=$?; env printf '\\n{s} {d} '\"$__qz_ec\"'\\n'\n", .{ salt, i });
            }
        }

        // Execute script via shell, merging stderr into stdout
        var child = std.process.Child.init(
            &.{ self.shell, "-c", "exec 2>&1; sh" },
            self.allocator,
        );
        child.stdin_behavior = .Pipe;
        // In debug mode, let output go directly to terminal
        child.stdout_behavior = if (debug) .Inherit else .Pipe;
        child.stderr_behavior = .Inherit;
        child.env_map = &self.env;
        child.cwd = self.tmpdir;

        try child.spawn();

        // Write script to stdin
        if (child.stdin) |stdin| {
            try stdin.writeAll(script.items);
            stdin.close();
            child.stdin = null;
        }

        if (debug) {
            // In debug mode, we don't capture output - just wait for completion
            // All commands are considered "passed" since we can't compare
            _ = try child.wait();
            for (0..commands.len) |_| {
                try results.append(self.allocator, .{ .output = "", .exit_code = 0 });
            }
            return results;
        }

        // Read combined output
        const output = try child.stdout.?.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(output);

        _ = try child.wait();

        // Parse output by salt markers
        const salt_pattern = try std.fmt.allocPrint(self.allocator, "{s} ", .{salt});
        defer self.allocator.free(salt_pattern);

        var current_output: std.ArrayListUnmanaged(u8) = .{};
        defer current_output.deinit(self.allocator);

        var output_iter = mem.splitScalar(u8, output, '\n');

        while (output_iter.next()) |line| {
            if (mem.startsWith(u8, line, salt_pattern)) {
                // Parse command index and exit code from this marker
                const rest = line[salt_pattern.len..];
                var parts = mem.splitScalar(u8, rest, ' ');
                const idx_str = parts.next() orelse continue;
                const idx = std.fmt.parseInt(usize, idx_str, 10) catch continue;
                const exit_str = parts.next() orelse "0";
                const exit_code = std.fmt.parseInt(u8, exit_str, 10) catch 0;

                // Trim exactly one trailing newline (the one we added before salt marker)
                var out = current_output.items;
                if (out.len > 0 and out[out.len - 1] == '\n') {
                    out = out[0 .. out.len - 1];
                }

                // Pad results array if needed
                while (results.items.len <= idx) {
                    try results.append(self.allocator, .{ .output = "", .exit_code = 0 });
                }
                results.items[idx] = .{
                    .output = try self.allocator.dupe(u8, out),
                    .exit_code = exit_code,
                };

                current_output.clearRetainingCapacity();
            } else {
                // Always append non-salt lines (including empty lines which represent blank output)
                try current_output.appendSlice(self.allocator, line);
                try current_output.append(self.allocator, '\n');
            }
        }

        return results;
    }
};

// Escape handling for binary output
pub fn escapeOutput(allocator: Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    for (input) |c| {
        switch (c) {
            '\t' => try result.appendSlice(allocator, "\\t"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f...0xff => {
                try result.writer(allocator).print("\\x{x:0>2}", .{c});
            },
            else => try result.append(allocator, c),
        }
    }
    return result.toOwnedSlice(allocator);
}

pub fn unescapeOutput(allocator: Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            switch (input[i + 1]) {
                't' => {
                    try result.append(allocator, '\t');
                    i += 2;
                },
                'r' => {
                    try result.append(allocator, '\r');
                    i += 2;
                },
                'n' => {
                    try result.append(allocator, '\n');
                    i += 2;
                },
                '\\' => {
                    try result.append(allocator, '\\');
                    i += 2;
                },
                'x' => {
                    if (i + 3 < input.len) {
                        const hex = input[i + 2 .. i + 4];
                        const byte = std.fmt.parseInt(u8, hex, 16) catch {
                            try result.append(allocator, input[i]);
                            i += 1;
                            continue;
                        };
                        try result.append(allocator, byte);
                        i += 4;
                    } else {
                        try result.append(allocator, input[i]);
                        i += 1;
                    }
                },
                else => {
                    try result.append(allocator, input[i]);
                    i += 1;
                },
            }
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(allocator);
}

// Matchers
pub fn matchLiteral(expected: []const u8, actual: []const u8) bool {
    return mem.eql(u8, expected, actual);
}

pub fn matchGlob(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: usize = 0;

    while (ti < text.len) {
        if (pi < pattern.len) {
            const pc = pattern[pi];
            if (pc == '*') {
                star_pi = pi;
                star_ti = ti;
                pi += 1;
                continue;
            } else if (pc == '?') {
                pi += 1;
                ti += 1;
                continue;
            } else if (pc == '\\' and pi + 1 < pattern.len) {
                if (pattern[pi + 1] == text[ti]) {
                    pi += 2;
                    ti += 1;
                    continue;
                }
            } else if (pc == text[ti]) {
                pi += 1;
                ti += 1;
                continue;
            }
        }

        // Mismatch - backtrack to last star
        if (star_pi) |sp| {
            pi = sp + 1;
            star_ti += 1;
            ti = star_ti;
        } else {
            return false;
        }
    }

    // Check remaining pattern is all stars
    while (pi < pattern.len and pattern[pi] == '*') {
        pi += 1;
    }

    return pi == pattern.len;
}

// Regex matching using PCRE2
pub fn matchRegex(pattern: []const u8, text: []const u8) bool {
    var err_code: c_int = 0;
    var err_off: pcre2.PCRE2_SIZE = 0;

    // Compile pattern (anchored to match full line like cram)
    const code = pcre2.pcre2_compile_8(
        pattern.ptr,
        pattern.len,
        pcre2.PCRE2_ANCHORED | pcre2.PCRE2_ENDANCHORED | pcre2.PCRE2_DOTALL,
        &err_code,
        &err_off,
        null,
    ) orelse return false;
    defer pcre2.pcre2_code_free_8(code);

    // Create match data
    const md = pcre2.pcre2_match_data_create_from_pattern_8(code, null) orelse return false;
    defer pcre2.pcre2_match_data_free_8(md);

    // Execute match
    const rc = pcre2.pcre2_match_8(
        code,
        text.ptr,
        text.len,
        0,
        0,
        md,
        null,
    );
    return rc >= 0;
}

pub fn matchLine(expected: ExpectedLine, actual: []const u8, allocator: Allocator) !bool {
    // Try literal match against original line first (handles cases like "foo (re)" as literal output)
    if (matchLiteral(expected.original, actual)) return true;

    // Then try pattern-stripped text literally
    if (matchLiteral(expected.text, actual)) return true;

    // Finally try pattern matching based on annotation
    switch (expected.matcher) {
        .literal => return false,
        .glob => return matchGlob(expected.text, actual),
        .regex => return matchRegex(expected.text, actual),
        .escape => {
            const unescaped = try unescapeOutput(allocator, expected.text);
            defer allocator.free(unescaped);
            return matchLiteral(unescaped, actual);
        },
    }
}

// Diff generation
pub const DiffResult = struct {
    lines: std.ArrayListUnmanaged(DiffLine),
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *DiffResult) void {
        self.arena.deinit();
    }
};

pub const DiffLine = struct {
    prefix: u8,
    content: []const u8,
};

pub fn generateDiff(
    child_allocator: Allocator,
    expected_lines: []const ExpectedLine,
    actual: []const u8,
    exit_code: u8,
) !DiffResult {
    var arena = std.heap.ArenaAllocator.init(child_allocator);
    const allocator = arena.allocator();

    var diff: std.ArrayListUnmanaged(DiffLine) = .{};

    var actual_lines: std.ArrayListUnmanaged([]const u8) = .{};
    // actual_lines memory is managed by arena

    if (actual.len > 0) {
        var iter = mem.splitScalar(u8, actual, '\n');
        while (iter.next()) |line| {
            try actual_lines.append(allocator, line);
        }
        if (actual_lines.items.len > 0 and actual_lines.items[actual_lines.items.len - 1].len == 0) {
            _ = actual_lines.pop();
        }
    }

    // Add exit code line if non-zero (cram format)
    if (exit_code != 0) {
        const exit_code_line = try std.fmt.allocPrint(allocator, "[{d}]", .{exit_code});
        try actual_lines.append(allocator, exit_code_line);
    }

    var ei: usize = 0;
    var ai: usize = 0;

    while (ei < expected_lines.len or ai < actual_lines.items.len) {
        if (ei < expected_lines.len and ai < actual_lines.items.len) {
            const exp = expected_lines[ei];
            const act = actual_lines.items[ai];

            if (try matchLine(exp, act, allocator)) {
                try diff.append(allocator, .{ .prefix = ' ', .content = act });
                ei += 1;
                ai += 1;
            } else {
                try diff.append(allocator, .{ .prefix = '-', .content = exp.text });
                try diff.append(allocator, .{ .prefix = '+', .content = act });
                ei += 1;
                ai += 1;
            }
        } else if (ei < expected_lines.len) {
            try diff.append(allocator, .{ .prefix = '-', .content = expected_lines[ei].text });
            ei += 1;
        } else if (ai < actual_lines.items.len) {
            try diff.append(allocator, .{ .prefix = '+', .content = actual_lines.items[ai] });
            ai += 1;
        }
    }

    return .{
        .lines = diff,
        .arena = arena,
    };
}

pub fn hasDifferences(diff: []const DiffLine) bool {
    for (diff) |line| {
        if (line.prefix != ' ') return true;
    }
    return false;
}

fn isPrintable(s: []const u8) bool {
    for (s) |c| {
        // Allow tab as printable-ish (common in text)
        if (c == '\t') continue;
        if (c < 0x20 or c >= 0x7f) return false;
    }
    return true;
}

// Test file runner
pub fn runTestFile(
    allocator: Allocator,
    path: []const u8,
    opts: *const Options,
) !TestFileResult {
    const content = try fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024);
    defer allocator.free(content);

    var parser = try Parser.init(allocator, content, opts.indent);
    defer parser.deinit();

    var commands = try parser.parse();
    defer {
        for (commands.items) |*cmd| {
            cmd.deinit();
        }
        commands.deinit(allocator);
    }

    if (commands.items.len == 0) {
        return .{ .passed = 0, .failed = 0, .skipped = 1 };
    }

    const basename = fs.path.basename(path);
    const dirname = fs.path.dirname(path) orelse ".";
    const abs_dirname = try fs.cwd().realpathAlloc(allocator, dirname);
    defer allocator.free(abs_dirname);

    // Create unique temp directory for this test (matches cram's structure)
    const timestamp = std.time.timestamp();
    const random_id = std.crypto.random.int(u64);
    const cramtmp = try std.fmt.allocPrint(allocator, "/tmp/cramtests-{d}-{x}", .{ timestamp, random_id });
    defer allocator.free(cramtmp);
    const tmpdir_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cramtmp, basename });
    defer allocator.free(tmpdir_name);

    // Create the temp directories
    fs.cwd().makePath(tmpdir_name) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer if (!opts.keep_tmpdir) {
        fs.cwd().deleteTree(cramtmp) catch {};
    };
    if (opts.keep_tmpdir) {
        getStderr().print("# Keeping tmpdir: {s}\n", .{cramtmp}) catch {};
    }

    var executor = try Executor.init(allocator, opts.shell, tmpdir_name, opts);
    defer executor.deinit();

    try executor.setTestEnv(abs_dirname, basename, opts.rootdir);

    var results = try executor.execute(commands.items, opts.debug);
    defer {
        for (results.items) |r| {
            allocator.free(r.output);
        }
        results.deinit(allocator);
    }

    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;

    for (commands.items, 0..) |cmd, i| {
        if (i >= results.items.len) {
            failed += 1;
            continue;
        }

        const result = results.items[i];

        if (result.exit_code == 80) {
            skipped += 1;
            continue;
        }

        var diff_result = try generateDiff(allocator, cmd.expected.items, result.output, result.exit_code);
        defer diff_result.deinit();
        const diff = diff_result.lines;

        const has_diff = hasDifferences(diff.items);

        if (has_diff) {
            failed += 1;

            if (!opts.quiet) {
                const out = getStdout();
                // Proper unified diff header
                try out.print("--- {s}\n+++ {s}\n", .{ path, path });

                // Calculate line numbers: expected output starts after command lines
                const start_line = cmd.line_num + cmd.lines.items.len;

                // Count old/new lines for hunk header
                var old_count: usize = 0;
                var new_count: usize = 0;
                for (diff.items) |line| {
                    if (line.prefix == '-' or line.prefix == ' ') old_count += 1;
                    if (line.prefix == '+' or line.prefix == ' ') new_count += 1;
                }

                // Hunk header
                try out.print("@@ -{d},{d} +{d},{d} @@\n", .{ start_line, old_count, start_line, new_count });

                // Output diff lines with indentation
                const indent = "  "; // 2-space indent for .t files
                for (diff.items) |line| {
                    if (isPrintable(line.content)) {
                        try out.print("{c}{s}{s}\n", .{ line.prefix, indent, line.content });
                    } else {
                        const escaped = try escapeOutput(allocator, line.content);
                        defer allocator.free(escaped);
                        try out.print("{c}{s}{s} (esc)\n", .{ line.prefix, indent, escaped });
                    }
                }
            }
        } else {
            passed += 1;
        }
    }

    return .{
        .passed = passed,
        .failed = failed,
        .skipped = skipped,
    };
}

pub const TestFileResult = struct {
    passed: usize,
    failed: usize,
    skipped: usize,
};

pub const EnvVar = struct {
    key: []const u8,
    value: []const u8,
};

pub const Options = struct {
    shell: []const u8 = "/bin/sh",
    indent: usize = 2,
    quiet: bool = false,
    verbose: bool = false,
    interactive: bool = false,
    debug: bool = false,
    inherit_env: bool = false,
    keep_tmpdir: bool = false,
    xunit_file: ?[]const u8 = null,
    // Collected from CLI, stored externally due to allocation
    bindirs: []const []const u8 = &.{},
    env_vars: []const EnvVar = &.{},
    rootdir: []const u8 = ".",
};

fn findTestFiles(allocator: Allocator, paths: []const []const u8) !std.ArrayListUnmanaged([]const u8) {
    var test_files: std.ArrayListUnmanaged([]const u8) = .{};

    for (paths) |path| {
        const stat = fs.cwd().statFile(path) catch |err| {
            getStderr().print("Error accessing {s}: {}\n", .{ path, err }) catch {};
            continue;
        };

        if (stat.kind == .directory) {
            var dir = try fs.cwd().openDir(path, .{ .iterate = true });
            defer dir.close();

            var walker = try dir.walk(allocator);
            defer walker.deinit();

            while (try walker.next()) |entry| {
                if (entry.kind == .file and mem.endsWith(u8, entry.basename, ".t")) {
                    if (entry.basename[0] == '.') continue;
                    const full_path = try fs.path.join(allocator, &.{ path, entry.path });
                    try test_files.append(allocator, full_path);
                }
            }
        } else {
            try test_files.append(allocator, try allocator.dupe(u8, path));
        }
    }

    mem.sort([]const u8, test_files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return mem.lessThan(u8, a, b);
        }
    }.lessThan);

    return test_files;
}

fn getStdout() std.fs.File.DeprecatedWriter {
    return std.fs.File.stdout().deprecatedWriter();
}

fn getStderr() std.fs.File.DeprecatedWriter {
    return std.fs.File.stderr().deprecatedWriter();
}

fn parseEnvVar(s: []const u8) ?EnvVar {
    const eq_pos = mem.indexOf(u8, s, "=") orelse return null;
    if (eq_pos == 0) return null;
    return .{
        .key = s[0..eq_pos],
        .value = s[eq_pos + 1 ..],
    };
}

fn printUsage() void {
    const usage =
        \\Usage: quizzig [OPTIONS] [TEST_FILES...]
        \\
        \\A shell testing framework written in Zig.
        \\
        \\Options:
        \\  -h, --help           Show this help message
        \\  -V, --version        Show version
        \\  -q, --quiet          Don't print diffs
        \\  -v, --verbose        Show filenames and status
        \\  -i, --interactive    Interactively update tests
        \\  -d, --debug          Write output directly to terminal
        \\  --keep-tmpdir        Don't remove temp directories
        \\  --shell=PATH         Shell to use (default: /bin/sh)
        \\  --indent=N           Indentation spaces (default: 2)
        \\  -E, --inherit-env    Inherit parent environment
        \\  -e, --env VAR=VAL    Set environment variable (repeatable)
        \\  --bindir=DIR         Prepend DIR to PATH (repeatable)
        \\
        \\Environment variables available in tests:
        \\  TESTDIR    Absolute path to test file's directory
        \\  TESTFILE   Test file basename
        \\  ROOTDIR    Directory where quizzig was invoked
        \\  CRAMTMP    Temp directory root
        \\  QUIZZIG    Always "1"
        \\
        \\Test files should have a .t extension.
        \\
    ;
    getStdout().print("{s}", .{usage}) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var opts = Options{};
    var paths: std.ArrayListUnmanaged([]const u8) = .{};
    defer paths.deinit(allocator);

    var bindirs: std.ArrayListUnmanaged([]const u8) = .{};
    defer bindirs.deinit(allocator);
    var env_vars: std.ArrayListUnmanaged(EnvVar) = .{};
    defer env_vars.deinit(allocator);

    // Capture rootdir (cwd where quizzig was invoked)
    const rootdir = try fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(rootdir);

    var args = try process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip();

    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (mem.eql(u8, arg, "-V") or mem.eql(u8, arg, "--version")) {
            getStdout().print("quizzig {s}\n", .{version}) catch {};
            return;
        } else if (mem.eql(u8, arg, "-q") or mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
        } else if (mem.eql(u8, arg, "-v") or mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (mem.eql(u8, arg, "-i") or mem.eql(u8, arg, "--interactive")) {
            opts.interactive = true;
        } else if (mem.eql(u8, arg, "-d") or mem.eql(u8, arg, "--debug")) {
            opts.debug = true;
        } else if (mem.eql(u8, arg, "--keep-tmpdir")) {
            opts.keep_tmpdir = true;
        } else if (mem.eql(u8, arg, "-E") or mem.eql(u8, arg, "--inherit-env")) {
            opts.inherit_env = true;
        } else if (mem.startsWith(u8, arg, "--shell=")) {
            opts.shell = arg[8..];
        } else if (mem.startsWith(u8, arg, "--indent=")) {
            opts.indent = try std.fmt.parseInt(usize, arg[9..], 10);
        } else if (mem.startsWith(u8, arg, "--bindir=")) {
            try bindirs.append(allocator, arg[9..]);
        } else if (mem.eql(u8, arg, "--bindir")) {
            if (args.next()) |dir| {
                try bindirs.append(allocator, dir);
            }
        } else if (mem.startsWith(u8, arg, "--env=")) {
            if (parseEnvVar(arg[6..])) |ev| {
                try env_vars.append(allocator, ev);
            }
        } else if (mem.eql(u8, arg, "--env") or mem.eql(u8, arg, "-e")) {
            if (args.next()) |val| {
                if (parseEnvVar(val)) |ev| {
                    try env_vars.append(allocator, ev);
                }
            }
        } else if (arg[0] != '-') {
            try paths.append(allocator, arg);
        }
    }

    opts.env_vars = env_vars.items;
    opts.rootdir = rootdir;

    // Resolve bindirs to absolute paths
    var abs_bindirs: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (abs_bindirs.items) |p| allocator.free(p);
        abs_bindirs.deinit(allocator);
    }

    for (bindirs.items) |dir| {
        const abs_dir = try fs.cwd().realpathAlloc(allocator, dir);
        try abs_bindirs.append(allocator, abs_dir);
    }
    opts.bindirs = abs_bindirs.items;

    if (paths.items.len == 0) {
        printUsage();
        return;
    }

    var test_files = try findTestFiles(allocator, paths.items);
    defer {
        for (test_files.items) |f| {
            allocator.free(f);
        }
        test_files.deinit(allocator);
    }

    if (test_files.items.len == 0) {
        getStderr().print("No test files found.\n", .{}) catch {};
        return;
    }

    const stderr = getStderr();
    var total_passed: usize = 0;
    var total_failed: usize = 0;
    var total_skipped: usize = 0;

    for (test_files.items) |test_path| {
        if (opts.verbose) {
            try stderr.print("{s}: ", .{test_path});
        }

        const result = runTestFile(allocator, test_path, &opts) catch |err| {
            try stderr.print("E", .{});
            if (opts.verbose) {
                try stderr.print(" error: {}\n", .{err});
            }
            total_failed += 1;
            continue;
        };

        total_passed += result.passed;
        total_failed += result.failed;
        total_skipped += result.skipped;

        if (result.failed > 0) {
            try stderr.print("!", .{});
        } else if (result.skipped > 0 and result.passed == 0) {
            try stderr.print("s", .{});
        } else {
            try stderr.print(".", .{});
        }

        if (opts.verbose) {
            try stderr.print("\n", .{});
        }
    }

    try stderr.print("\n# Ran {d} tests, {d} skipped, {d} failed.\n", .{
        total_passed + total_failed,
        total_skipped,
        total_failed,
    });

    if (total_failed > 0) {
        process.exit(1);
    }
}

test "glob matching" {
    try std.testing.expect(matchGlob("foo*", "foobar"));
    try std.testing.expect(matchGlob("*.txt", "hello.txt"));
    try std.testing.expect(matchGlob("file?.txt", "file1.txt"));
    try std.testing.expect(!matchGlob("file?.txt", "file12.txt"));
    try std.testing.expect(matchGlob("*", "anything"));
    try std.testing.expect(matchGlob("a*b*c", "aXXbYYc"));
}

test "regex matching" {
    try std.testing.expect(matchRegex("foo.*", "foobar"));
    try std.testing.expect(matchRegex("\\d\\d\\d", "123"));
    try std.testing.expect(matchRegex("hello", "hello"));
    try std.testing.expect(!matchRegex("hello", "world"));
    try std.testing.expect(matchRegex(".*bar", "foobar"));
    try std.testing.expect(matchRegex("foo.+", "foobar"));
}

test "escape/unescape" {
    const allocator = std.testing.allocator;

    const escaped = try escapeOutput(allocator, "hello\tworld\x00");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("hello\\tworld\\x00", escaped);

    const unescaped = try unescapeOutput(allocator, "hello\\tworld\\x00");
    defer allocator.free(unescaped);
    try std.testing.expectEqualStrings("hello\tworld\x00", unescaped);
}
