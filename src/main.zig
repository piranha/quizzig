const std = @import("std");
const opt = @import("opt");
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
                try diff.append(allocator, .{ .prefix = ' ', .content = exp.original });
                ei += 1;
                ai += 1;
            } else {
                // Collect consecutive mismatches, then output grouped (all - then all +)
                var removed: std.ArrayListUnmanaged([]const u8) = .{};
                var added: std.ArrayListUnmanaged([]const u8) = .{};

                while (ei < expected_lines.len and ai < actual_lines.items.len) {
                    const e = expected_lines[ei];
                    const a = actual_lines.items[ai];
                    if (try matchLine(e, a, allocator)) break;
                    try removed.append(allocator, e.original);
                    try added.append(allocator, a);
                    ei += 1;
                    ai += 1;
                }

                // Output all removals first, then all additions
                for (removed.items) |line| {
                    try diff.append(allocator, .{ .prefix = '-', .content = line });
                }
                for (added.items) |line| {
                    try diff.append(allocator, .{ .prefix = '+', .content = line });
                }
            }
        } else if (ei < expected_lines.len) {
            try diff.append(allocator, .{ .prefix = '-', .content = expected_lines[ei].original });
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

pub const Hunk = struct {
    start_idx: usize, // index into original diff lines
    end_idx: usize, // exclusive
    old_start: usize, // 1-based line number in old file
    old_count: usize,
    new_count: usize,
};

const CONTEXT_LINES = 3;

const Range = struct { start: usize, end: usize };

/// Convert flat diff lines into hunks with limited context (3 lines before/after changes)
pub fn generateHunks(allocator: Allocator, diff: []const DiffLine) !std.ArrayListUnmanaged(Hunk) {
    var hunks: std.ArrayListUnmanaged(Hunk) = .{};

    if (diff.len == 0) return hunks;

    // Find all change positions (non-context lines)
    var change_ranges: std.ArrayListUnmanaged(Range) = .{};
    defer change_ranges.deinit(allocator);

    var i: usize = 0;
    while (i < diff.len) {
        if (diff[i].prefix != ' ') {
            const start = i;
            while (i < diff.len and diff[i].prefix != ' ') : (i += 1) {}
            try change_ranges.append(allocator, .{ .start = start, .end = i });
        } else {
            i += 1;
        }
    }

    if (change_ranges.items.len == 0) return hunks;

    // Merge change ranges that are within 2*CONTEXT_LINES of each other
    var merged: std.ArrayListUnmanaged(Range) = .{};
    defer merged.deinit(allocator);

    var current = change_ranges.items[0];
    for (change_ranges.items[1..]) |next| {
        // If gap between end of current and start of next is <= 2*CONTEXT_LINES, merge
        if (next.start <= current.end + 2 * CONTEXT_LINES) {
            current.end = next.end;
        } else {
            try merged.append(allocator, current);
            current = next;
        }
    }
    try merged.append(allocator, current);

    // Convert merged ranges to hunks with context
    var old_line: usize = 1; // 1-based line number tracking
    var diff_idx: usize = 0;

    for (merged.items) |range| {
        // Advance old_line to account for lines before this range
        while (diff_idx < range.start) {
            if (diff[diff_idx].prefix == ' ' or diff[diff_idx].prefix == '-') {
                old_line += 1;
            }
            diff_idx += 1;
        }

        // Calculate context bounds
        const ctx_start = if (range.start >= CONTEXT_LINES) range.start - CONTEXT_LINES else 0;
        const ctx_end = @min(range.end + CONTEXT_LINES, diff.len);

        // Calculate old_start (need to back up for leading context)
        var hunk_old_start = old_line;
        var back: usize = range.start;
        while (back > ctx_start) {
            back -= 1;
            if (diff[back].prefix == ' ' or diff[back].prefix == '-') {
                hunk_old_start -= 1;
            }
        }

        // Count old/new lines in hunk
        var old_count: usize = 0;
        var new_count: usize = 0;
        for (diff[ctx_start..ctx_end]) |line| {
            if (line.prefix == ' ' or line.prefix == '-') old_count += 1;
            if (line.prefix == ' ' or line.prefix == '+') new_count += 1;
        }

        try hunks.append(allocator, .{
            .start_idx = ctx_start,
            .end_idx = ctx_end,
            .old_start = hunk_old_start,
            .old_count = old_count,
            .new_count = new_count,
        });

        // Advance to end of this range
        while (diff_idx < range.end) {
            if (diff[diff_idx].prefix == ' ' or diff[diff_idx].prefix == '-') {
                old_line += 1;
            }
            diff_idx += 1;
        }
    }

    return hunks;
}

pub fn hasDifferences(diff: []const DiffLine) bool {
    for (diff) |line| {
        if (line.prefix != ' ') return true;
    }
    return false;
}

fn needsEscaping(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        // Control chars (except tab) need escaping
        if (c < 0x20 and c != '\t') return true;
        if (c == 0x7f) return true;
        // ASCII printable is fine
        if (c < 0x80) {
            i += 1;
            continue;
        }
        // Check for valid UTF-8 sequence
        const seq_len: usize = if (c < 0xc0) 0 // Invalid leading byte
        else if (c < 0xe0) 2
        else if (c < 0xf0) 3
        else if (c < 0xf8) 4
        else 0; // Invalid
        if (seq_len == 0 or i + seq_len > s.len) return true; // Invalid UTF-8
        // Verify continuation bytes (must be 10xxxxxx)
        for (s[i + 1 .. i + seq_len]) |cont| {
            if (cont < 0x80 or cont >= 0xc0) return true; // Invalid continuation
        }
        i += seq_len;
    }
    return false;
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
        var skipped_tests: std.ArrayListUnmanaged(SkippedTest) = .{};
        try skipped_tests.append(allocator, .{ .file = path, .line = 0, .command = try allocator.dupe(u8, "(no commands)") });
        return .{ .passed = 0, .failed = 0, .skipped = 1, .skipped_tests = skipped_tests, .diff_output = "", .patched_content = null };
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
    var skipped_tests: std.ArrayListUnmanaged(SkippedTest) = .{};

    // For --patch mode: track line replacements (start_line, end_line exclusive, new_lines)
    const Correction = struct {
        start_line: usize, // 1-based, inclusive
        end_line: usize, // 1-based, exclusive
        new_lines: std.ArrayListUnmanaged([]const u8),
    };
    var corrections: std.ArrayListUnmanaged(Correction) = .{};
    defer {
        for (corrections.items) |*c| {
            for (c.new_lines.items) |line| allocator.free(line);
            c.new_lines.deinit(allocator);
        }
        corrections.deinit(allocator);
    }

    // Collect all file-level diff entries (file_line -> list of diff lines)
    // For added lines, file_line is where they insert after
    const FileDiffLine = struct {
        prefix: u8,
        content: []const u8, // owned by arena
        is_escaped: bool,
    };
    var file_diff_arena = std.heap.ArenaAllocator.init(allocator);
    defer file_diff_arena.deinit();
    const diff_alloc = file_diff_arena.allocator();

    // Map from file line (1-based) to diff lines at that position
    // Context lines use their actual file line, changes use the old file line
    var diff_at_line = std.AutoHashMap(usize, std.ArrayListUnmanaged(FileDiffLine)).init(allocator);
    defer {
        var it = diff_at_line.valueIterator();
        while (it.next()) |list| {
            list.deinit(allocator);
        }
        diff_at_line.deinit();
    }

    for (commands.items, 0..) |cmd, i| {
        if (i >= results.items.len) {
            failed += 1;
            continue;
        }

        const result = results.items[i];

        if (result.exit_code == 80) {
            skipped += 1;
            const first_line = if (cmd.lines.items.len > 0) cmd.lines.items[0] else "";
            const cmd_dupe = try allocator.dupe(u8, first_line);
            try skipped_tests.append(allocator, .{ .file = path, .line = cmd.line_num, .command = cmd_dupe });
            continue;
        }

        var diff_result = try generateDiff(allocator, cmd.expected.items, result.output, result.exit_code);
        defer diff_result.deinit();
        const diff = diff_result.lines;

        const has_diff = hasDifferences(diff.items);

        if (has_diff) {
            failed += 1;

            // For --patch mode: record the correction
            if (opts.patch) {
                const start_line = cmd.line_num + cmd.lines.items.len;
                const end_line = start_line + cmd.expected.items.len;
                const indent_str = "    "; // TODO: use opts.indent

                var new_lines: std.ArrayListUnmanaged([]const u8) = .{};

                // Parse actual output into lines
                if (result.output.len > 0) {
                    var iter = mem.splitScalar(u8, result.output, '\n');
                    while (iter.next()) |line| {
                        // Skip trailing empty line from split
                        if (iter.peek() == null and line.len == 0) break;
                        const needs_esc = needsEscaping(line);
                        const formatted = if (needs_esc) blk: {
                            const escaped = try escapeOutput(allocator, line);
                            defer allocator.free(escaped);
                            break :blk try std.fmt.allocPrint(allocator, "{s}{s} (esc)", .{ indent_str, escaped });
                        } else try std.fmt.allocPrint(allocator, "{s}{s}", .{ indent_str, line });
                        try new_lines.append(allocator, formatted);
                    }
                }

                // Add exit code line if non-zero
                if (result.exit_code != 0) {
                    const exit_line = try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ indent_str, result.exit_code });
                    try new_lines.append(allocator, exit_line);
                }

                try corrections.append(allocator, .{
                    .start_line = start_line,
                    .end_line = end_line,
                    .new_lines = new_lines,
                });
            }

            if (!opts.quiet) {
                const start_line = cmd.line_num + cmd.lines.items.len;
                const indent = "    ";

                // Track file line as we walk through diff
                // Additions (+) stay at same position as preceding removal/context
                var file_line = start_line;
                var store_at = start_line;
                for (diff.items) |line| {
                    if (line.prefix != '+') {
                        store_at = file_line;
                    }

                    const needs_esc = line.prefix == '+' and needsEscaping(line.content);
                    const line_content = if (needs_esc)
                        try std.fmt.allocPrint(diff_alloc, "{s}{s} (esc)", .{ indent, try escapeOutput(diff_alloc, line.content) })
                    else
                        try std.fmt.allocPrint(diff_alloc, "{s}{s}", .{ indent, line.content });

                    const entry = try diff_at_line.getOrPut(store_at);
                    if (!entry.found_existing) {
                        entry.value_ptr.* = .{};
                    }
                    try entry.value_ptr.append(allocator, .{
                        .prefix = line.prefix,
                        .content = line_content,
                        .is_escaped = needs_esc,
                    });

                    // Advance file_line for context and removed lines (not added)
                    if (line.prefix != '+') {
                        file_line += 1;
                    }
                }
            }
        } else {
            passed += 1;
        }
    }

    // Generate merged hunks from collected diff data
    if (diff_at_line.count() > 0 and !opts.quiet) {
        // Get sorted list of file lines that have changes
        var change_lines: std.ArrayListUnmanaged(usize) = .{};
        defer change_lines.deinit(allocator);

        var kit = diff_at_line.keyIterator();
        while (kit.next()) |key| {
            // Only include lines that have actual changes (not just context)
            const lines = diff_at_line.get(key.*).?;
            for (lines.items) |line| {
                if (line.prefix != ' ') {
                    try change_lines.append(allocator, key.*);
                    break;
                }
            }
        }

        if (change_lines.items.len > 0) {
            std.mem.sort(usize, change_lines.items, {}, std.sort.asc(usize));

            // Merge into ranges with context
            var ranges: std.ArrayListUnmanaged(Range) = .{};
            defer ranges.deinit(allocator);

            var current_start = if (change_lines.items[0] > CONTEXT_LINES) change_lines.items[0] - CONTEXT_LINES else 1;
            var current_end = change_lines.items[0] + CONTEXT_LINES + 1;

            for (change_lines.items[1..]) |line| {
                const range_start = if (line > CONTEXT_LINES) line - CONTEXT_LINES else 1;
                const range_end = line + CONTEXT_LINES + 1;

                if (range_start <= current_end) {
                    // Overlaps or touches, extend
                    current_end = @max(current_end, range_end);
                } else {
                    // Gap, save current and start new
                    try ranges.append(allocator, .{ .start = current_start, .end = current_end });
                    current_start = range_start;
                    current_end = range_end;
                }
            }
            try ranges.append(allocator, .{ .start = current_start, .end = current_end });

            // Collect diff output to buffer
            var diff_output: std.ArrayListUnmanaged(u8) = .{};
            errdefer diff_output.deinit(allocator);

            try diff_output.writer(allocator).print("--- {s}\n+++ {s}\n", .{ path, path });

            for (ranges.items) |range| {
                // Collect lines for this hunk
                var old_count: usize = 0;
                var new_count: usize = 0;
                var hunk_content: std.ArrayListUnmanaged(u8) = .{};
                defer hunk_content.deinit(allocator);

                var line_num = range.start;
                while (line_num < range.end) {
                    if (diff_at_line.get(line_num)) |diff_lines| {
                        // Output diff lines at this position
                        for (diff_lines.items) |dl| {
                            try hunk_content.writer(allocator).print("{c}{s}\n", .{ dl.prefix, dl.content });
                            if (dl.prefix == ' ' or dl.prefix == '-') old_count += 1;
                            if (dl.prefix == ' ' or dl.prefix == '+') new_count += 1;
                        }
                        // Check if we consumed a file line (context or removal)
                        var consumed = false;
                        for (diff_lines.items) |dl| {
                            if (dl.prefix != '+') {
                                consumed = true;
                                break;
                            }
                        }
                        if (consumed) {
                            line_num += 1;
                        } else {
                            line_num += 1;
                        }
                    } else {
                        // No diff at this line, emit as context from file
                        const file_idx = line_num - 1;
                        if (file_idx < parser.lines.items.len) {
                            const file_line = parser.lines.items[file_idx];
                            const is_eof_phantom = file_idx == parser.lines.items.len - 1 and file_line.len == 0;
                            if (!is_eof_phantom) {
                                try hunk_content.writer(allocator).print(" {s}\n", .{file_line});
                                old_count += 1;
                                new_count += 1;
                            }
                        }
                        line_num += 1;
                    }
                }

                try diff_output.writer(allocator).print("@@ -{d},{d} +{d},{d} @@\n", .{ range.start, old_count, range.start, new_count });
                try diff_output.appendSlice(allocator, hunk_content.items);
            }

            // Generate patched content if in patch mode
            const patched = if (opts.patch and corrections.items.len > 0) blk: {
                var patched_content: std.ArrayListUnmanaged(u8) = .{};
                var src_line: usize = 1;

                // Sort corrections by start_line
                std.mem.sort(Correction, corrections.items, {}, struct {
                    fn lessThan(_: void, a: Correction, b: Correction) bool {
                        return a.start_line < b.start_line;
                    }
                }.lessThan);

                for (corrections.items) |corr| {
                    // Copy lines before this correction
                    while (src_line < corr.start_line) : (src_line += 1) {
                        const idx = src_line - 1;
                        if (idx < parser.lines.items.len) {
                            try patched_content.appendSlice(allocator, parser.lines.items[idx]);
                            try patched_content.append(allocator, '\n');
                        }
                    }
                    // Insert corrected lines
                    for (corr.new_lines.items) |new_line| {
                        try patched_content.appendSlice(allocator, new_line);
                        try patched_content.append(allocator, '\n');
                    }
                    // Skip old expected output lines
                    src_line = corr.end_line;
                }
                // Copy remaining lines
                while (src_line <= parser.lines.items.len) : (src_line += 1) {
                    const idx = src_line - 1;
                    if (idx < parser.lines.items.len) {
                        try patched_content.appendSlice(allocator, parser.lines.items[idx]);
                        if (src_line < parser.lines.items.len) {
                            try patched_content.append(allocator, '\n');
                        }
                    }
                }
                break :blk try patched_content.toOwnedSlice(allocator);
            } else null;

            return .{
                .passed = passed,
                .failed = failed,
                .skipped = skipped,
                .skipped_tests = skipped_tests,
                .diff_output = try diff_output.toOwnedSlice(allocator),
                .patched_content = patched,
            };
        }
    }

    return .{
        .passed = passed,
        .failed = failed,
        .skipped = skipped,
        .skipped_tests = skipped_tests,
        .diff_output = "",
        .patched_content = null,
    };
}

pub const SkippedTest = struct {
    file: []const u8,
    line: usize,
    command: []const u8,
};

pub const TestFileResult = struct {
    passed: usize,
    failed: usize,
    skipped: usize,
    skipped_tests: std.ArrayListUnmanaged(SkippedTest),
    diff_output: []const u8, // owned, caller must free
    patched_content: ?[]const u8, // if patch mode, the corrected file content
};

pub const EnvVar = struct {
    key: []const u8,
    value: []const u8,
};

pub const Options = struct {
    shell: []const u8 = "/bin/sh",
    indent: usize = 4,
    quiet: bool = false,
    verbose: bool = false,
    patch: bool = false,
    debug: bool = false,
    inherit_env: bool = false,
    keep_tmpdir: bool = false,
    xunit_file: ?[]const u8 = null,
    bindirs: []const []const u8 = &.{},
    env_vars: []const EnvVar = &.{},
    rootdir: []const u8 = ".",
};

const CliOptions = struct {
    shell: []const u8 = "/bin/sh",
    indent: usize = 4,
    quiet: bool = false,
    verbose: bool = false,
    patch: bool = false,
    debug: bool = false,
    @"inherit-env": bool = false,
    @"keep-tmpdir": bool = false,
    bindir: opt.Multi([]const u8, 16) = .{},
    env: opt.Multi([]const u8, 32) = .{},
    version: bool = false,

    pub const meta = .{
        .shell = .{ .help = "Shell to use" },
        .indent = .{ .help = "Indentation spaces" },
        .quiet = .{ .short = 'q', .help = "Don't print diffs" },
        .verbose = .{ .short = 'v', .help = "Show filenames and status" },
        .patch = .{ .short = 'i', .help = "Auto-apply fixes to test files" },
        .debug = .{ .short = 'd', .help = "Write output directly to terminal" },
        .@"inherit-env" = .{ .short = 'E', .help = "Inherit parent environment" },
        .@"keep-tmpdir" = .{ .help = "Don't remove temp directories" },
        .bindir = .{ .help = "Prepend DIR to PATH (repeatable)" },
        .env = .{ .short = 'e', .help = "Set environment variable VAR=VAL (repeatable)" },
        .version = .{ .short = 'V', .help = "Show version" },
    };

    pub const about = .{
        .name = "quizzig",
        .desc = "A shell testing framework written in Zig.",
    };
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
                if (entry.kind == .file and (mem.endsWith(u8, entry.basename, ".t") or mem.endsWith(u8, entry.basename, ".md"))) {
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
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    opt.printUsage(CliOptions, &stdout.interface);
    stdout.interface.flush() catch {};
    getStdout().print(
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
    , .{}) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Capture rootdir (cwd where quizzig was invoked)
    const rootdir = try fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(rootdir);

    // Collect args into slice for opt.parse (skip argv[0])
    var args_list: std.ArrayListUnmanaged([]const u8) = .{};
    defer args_list.deinit(allocator);
    var args_iter = process.args();
    _ = args_iter.skip(); // skip program name
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }

    // Parse CLI options
    var cli_opts = CliOptions{};
    const paths = opt.parse(CliOptions, &cli_opts, args_list.items) catch |err| {
        if (err == error.Help) {
            printUsage();
            return;
        }
        getStderr().print("Error: {}\n", .{err}) catch {};
        return;
    };

    if (cli_opts.version) {
        getStdout().print("quizzig {s}\n", .{version}) catch {};
        return;
    }

    // Convert env strings to EnvVar structs
    var env_vars: std.ArrayListUnmanaged(EnvVar) = .{};
    defer env_vars.deinit(allocator);
    for (cli_opts.env.constSlice()) |ev_str| {
        if (parseEnvVar(ev_str)) |ev| {
            try env_vars.append(allocator, ev);
        }
    }

    // Resolve bindirs to absolute paths
    var abs_bindirs: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (abs_bindirs.items) |p| allocator.free(p);
        abs_bindirs.deinit(allocator);
    }
    for (cli_opts.bindir.constSlice()) |dir| {
        const abs_dir = try fs.cwd().realpathAlloc(allocator, dir);
        try abs_bindirs.append(allocator, abs_dir);
    }

    // Build internal Options struct
    var opts = Options{
        .shell = cli_opts.shell,
        .indent = cli_opts.indent,
        .quiet = cli_opts.quiet,
        .verbose = cli_opts.verbose,
        .patch = cli_opts.patch,
        .debug = cli_opts.debug,
        .inherit_env = cli_opts.@"inherit-env",
        .keep_tmpdir = cli_opts.@"keep-tmpdir",
        .bindirs = abs_bindirs.items,
        .env_vars = env_vars.items,
        .rootdir = rootdir,
    };

    if (paths.len == 0) {
        printUsage();
        return;
    }

    var test_files = try findTestFiles(allocator, paths);
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
    var all_skipped: std.ArrayListUnmanaged(SkippedTest) = .{};
    defer {
        for (all_skipped.items) |s| allocator.free(s.command);
        all_skipped.deinit(allocator);
    }
    var all_diffs: std.ArrayListUnmanaged(u8) = .{};
    defer all_diffs.deinit(allocator);

    for (test_files.items) |test_path| {
        if (opts.verbose) {
            try stderr.print("{s}: ", .{test_path});
        }

        var result = runTestFile(allocator, test_path, &opts) catch |err| {
            try stderr.print("E", .{});
            if (opts.verbose) {
                try stderr.print(" error: {}\n", .{err});
            }
            total_failed += 1;
            continue;
        };
        defer result.skipped_tests.deinit(allocator);
        defer if (result.diff_output.len > 0) allocator.free(result.diff_output);
        defer if (result.patched_content) |p| allocator.free(p);

        total_passed += result.passed;
        total_failed += result.failed;
        total_skipped += result.skipped;
        try all_skipped.appendSlice(allocator, result.skipped_tests.items);

        // Write patched content if in patch mode
        if (result.patched_content) |patched| {
            var file = try fs.cwd().createFile(test_path, .{});
            defer file.close();
            try file.writeAll(patched);
            // Treat patched files as "fixed" - adjust counts
            total_failed -= result.failed;
            total_passed += result.failed;
        }

        // Collect diff output to print after progress
        if (result.diff_output.len > 0 and !opts.patch) {
            try all_diffs.appendSlice(allocator, result.diff_output);
        }

        if (result.patched_content != null) {
            try stderr.print("P", .{}); // Patched
        } else if (result.failed > 0) {
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

    // Print all diffs after progress indicators
    if (all_diffs.items.len > 0) {
        try stderr.print("\n", .{});
        const stdout = getStdout();
        try stdout.print("{s}", .{all_diffs.items});
    }

    try stderr.print("\n# Ran {d} tests, {d} skipped, {d} failed.\n", .{
        total_passed + total_failed,
        total_skipped,
        total_failed,
    });

    if (all_skipped.items.len > 0 and opts.verbose) {
        try stderr.print("# Skipped:\n", .{});
        for (all_skipped.items) |s| {
            if (s.line == 0) {
                try stderr.print("#   {s}: {s}\n", .{ s.file, s.command });
            } else {
                try stderr.print("#   {s}:{d}: {s}\n", .{ s.file, s.line, s.command });
            }
        }
    }

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
