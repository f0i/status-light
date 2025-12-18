const std = @import("std");
const os = std.os;
const fs = std.fs;
const process = std.process;
const posix = std.posix;

const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("termios.h");
    @cInclude("pty.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
});

extern var environ: [*:null]?[*:0]u8;

const State = enum {
    idle,
    thinking,
    waiting,
};

const Config = struct {
    patterns: Patterns,
    idle_threshold_ms: u64,

    const Patterns = struct {
        waiting: []const []const u8,
        thinking: []const []const u8,
    };
};

const DebugLogger = struct {
    file: ?fs.File,

    fn init() DebugLogger {
        const debug_env = std.posix.getenv("DEBUG_SL");
        if (debug_env == null) return .{ .file = null };

        const file = fs.cwd().createFile("debug.log", .{ .truncate = true }) catch null;
        return .{ .file = file };
    }

    fn deinit(self: *DebugLogger) void {
        if (self.file) |f| {
            f.close();
        }
    }

    fn log(self: *const DebugLogger, comptime fmt: []const u8, args: anytype) void {
        if (self.file) |f| {
            f.writer().print(fmt, args) catch {};
        }
    }
};

const LEDController = struct {
    fd: ?posix.fd_t,

    fn init() LEDController {
        const fd = posix.open("/dev/ttyACM0", .{ .ACCMODE = .WRONLY }, 0) catch null;
        return .{ .fd = fd };
    }

    fn deinit(self: *LEDController) void {
        if (self.fd) |fd| {
            posix.close(fd);
        }
    }

    fn setState(self: *LEDController, state: State, logger: *const DebugLogger) void {
        // Match Python version: write directly to serial
        // idle: blue "a 000 000 000 255"
        // thinking: yellow "a 000 255 255 000"
        // waiting: red "a 000 255 000 000"
        const cmd = switch (state) {
            .idle => "a 000 000 000 255\n",
            .thinking => "a 000 255 255 000\n",
            .waiting => "a 000 255 000 000\n",
        };

        logger.log("[DEBUG] LED State: {s} -> {s}", .{ @tagName(state), cmd });

        if (self.fd) |fd| {
            _ = posix.write(fd, cmd) catch |err| {
                logger.log("LED write error: {}\n", .{err});
            };
        }
    }

    fn turnOff(self: *LEDController, logger: *const DebugLogger) void {
        const cmd = "o\n"; // Turn off command
        logger.log("[DEBUG] LED: turning off\n", .{});

        if (self.fd) |fd| {
            _ = posix.write(fd, cmd) catch |err| {
                logger.log("LED write error: {}\n", .{err});
            };
        }
    }
};

const CompiledPattern = struct {
    pattern: []const u8,
    allocator: std.mem.Allocator,

    fn compile(allocator: std.mem.Allocator, pattern: []const u8) !CompiledPattern {
        var self: CompiledPattern = undefined;
        self.allocator = allocator;
        self.pattern = try allocator.dupe(u8, pattern);
        return self;
    }

    fn deinit(self: *CompiledPattern) void {
        self.allocator.free(self.pattern);
    }

    fn matches(self: *const CompiledPattern, text: []const u8) !bool {
        return std.mem.indexOf(u8, text, self.pattern) != null;
    }
};

const PatternMatcher = struct {
    waiting_patterns: []CompiledPattern,
    thinking_patterns: []CompiledPattern,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, config: Config) !PatternMatcher {
        var waiting = try allocator.alloc(CompiledPattern, config.patterns.waiting.len);
        errdefer allocator.free(waiting);

        for (config.patterns.waiting, 0..) |pattern, i| {
            waiting[i] = try CompiledPattern.compile(allocator, pattern);
        }

        var thinking = try allocator.alloc(CompiledPattern, config.patterns.thinking.len);
        errdefer {
            allocator.free(thinking);
            for (waiting) |*p| p.deinit();
            allocator.free(waiting);
        }

        for (config.patterns.thinking, 0..) |pattern, i| {
            thinking[i] = try CompiledPattern.compile(allocator, pattern);
        }

        return .{
            .waiting_patterns = waiting,
            .thinking_patterns = thinking,
            .allocator = allocator,
        };
    }

    fn deinit(self: *PatternMatcher) void {
        for (self.waiting_patterns) |*p| p.deinit();
        for (self.thinking_patterns) |*p| p.deinit();
        self.allocator.free(self.waiting_patterns);
        self.allocator.free(self.thinking_patterns);
    }

    fn matchState(self: *const PatternMatcher, full_buffer: []const u8, logger: *const DebugLogger) !?State {
        // Get tail (last ~10 lines) for checking UI state indicators (waiting patterns)
        // Waiting patterns should only match on recent output, not old buffered text
        const tail_start = blk: {
            var count: usize = 0;
            var i: usize = full_buffer.len;
            while (i > 0 and count < 10) : (i -= 1) {
                if (full_buffer[i - 1] == '\n') count += 1;
            }
            break :blk i;
        };
        const tail = full_buffer[tail_start..];

        // Check waiting patterns on tail only (last ~10 lines) - these are UI state indicators
        for (self.waiting_patterns) |*pattern| {
            if (try pattern.matches(tail)) {
                logger.log("[DEBUG] State: WAITING (matched: {s} in tail)\n", .{pattern.pattern});
                return .waiting;
            }
        }

        // Check thinking patterns on full buffer - thinking indicators can appear anywhere
        const has_imagining_check = std.mem.indexOf(u8, full_buffer, "Imagining") != null;

        for (self.thinking_patterns) |*pattern| {
            const matched = try pattern.matches(full_buffer);

            // Debug when we have "Imagining" in buffer
            if (has_imagining_check) {
                logger.log("[DEBUG] Checking thinking pattern '{s}': matched={}\n", .{ pattern.pattern, matched });
            }

            if (matched) {
                logger.log("[DEBUG] State: THINKING (matched: {s} in full buffer)\n", .{pattern.pattern});
                return .thinking;
            }
        }

        return null;
    }
};

const ConfigResult = struct {
    config: Config,
    parsed: ?std.json.Parsed(Config),

    fn deinit(self: *ConfigResult) void {
        if (self.parsed) |*p| {
            p.deinit();
        }
    }
};

fn loadConfig(allocator: std.mem.Allocator, tool_name: []const u8) !ConfigResult {
    const config_paths = [_][]const u8{
        try std.fmt.allocPrint(allocator, "configs/{s}.json", .{tool_name}),
        "configs/default.json",
    };
    defer allocator.free(config_paths[0]);

    for (config_paths) |path| {
        const file = fs.cwd().openFile(path, .{}) catch continue;
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        const parsed = try std.json.parseFromSlice(Config, allocator, content, .{
            .allocate = .alloc_always,
        });

        return .{ .config = parsed.value, .parsed = parsed };
    }

    // Built-in default config
    return .{
        .config = Config{
            .patterns = .{
                .waiting = &[_][]const u8{
                    "wait",
                    "Wait",
                    "\\(y/n\\)",
                },
                .thinking = &[_][]const u8{
                    "build",
                    "Build",
                    "running",
                    "Running",
                    "imagining",
                    "Imagining",
                },
            },
            .idle_threshold_ms = 500,
        },
        .parsed = null,
    };
}

fn getTerminalSize() ?c.winsize {
    var ws: c.winsize = undefined;
    if (c.ioctl(posix.STDOUT_FILENO, c.TIOCGWINSZ, &ws) < 0) {
        return null;
    }
    return ws;
}

fn openPty() !struct { master: posix.fd_t, slave: posix.fd_t } {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    var name_buf: [256]u8 = undefined;

    const ws = getTerminalSize();

    const ws_ptr = if (ws) |*w| w else null;

    if (c.openpty(&master, &slave, &name_buf, null, ws_ptr) < 0) {
        return error.OpenPtyFailed;
    }

    return .{
        .master = @intCast(master),
        .slave = @intCast(slave),
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <command> [args...]\n", .{args[0]});
        return error.InvalidArguments;
    }

    const tool_name = fs.path.basename(args[1]);

    // Open PTY
    const pty = try openPty();
    defer posix.close(pty.master);
    defer posix.close(pty.slave);

    // Fork child process
    const pid = try posix.fork();

    if (pid == 0) {
        // Child process
        _ = c.setsid();
        _ = c.ioctl(pty.slave, c.TIOCSCTTY, @as(c_int, 0));

        posix.dup2(pty.slave, posix.STDIN_FILENO) catch {};
        posix.dup2(pty.slave, posix.STDOUT_FILENO) catch {};
        posix.dup2(pty.slave, posix.STDERR_FILENO) catch {};

        posix.close(pty.master);
        posix.close(pty.slave);

        // We need to create null-terminated versions of the arguments
        var argv_ptrs = try allocator.alloc(?[*:0]u8, args[1..].len + 1);
        defer allocator.free(argv_ptrs);

        for (args[1..], 0..) |arg, i| {
            argv_ptrs[i] = try allocator.dupeZ(u8, arg);
        }
        argv_ptrs[args[1..].len] = null;

        posix.execvpeZ(
            argv_ptrs[0].?,
            @as([*:null]const ?[*:0]const u8, @ptrCast(argv_ptrs.ptr)),
            @ptrCast(environ),
        ) catch {
            _ = c.write(posix.STDERR_FILENO, "Child process failed to exec\n", 29);
            process.exit(1);
        };
    }

    // Parent process - monitor PTY
    var buffer: [1024]u8 = undefined;

    // Line-based buffer: keep last ~100 lines, max 50KB total
    var line_buffer = std.ArrayList([]const u8).init(allocator);
    defer {
        for (line_buffer.items) |line| allocator.free(line);
        line_buffer.deinit();
    }
    var total_buffer_bytes: usize = 0;
    const max_buffer_bytes: usize = 50 * 1024;
    const max_lines: usize = 100;

    var current_state: State = .idle;
    var last_output_time = std.time.milliTimestamp();
    var last_state_change = std.time.milliTimestamp();
    var last_thinking_pattern_time = std.time.milliTimestamp();
    const min_state_duration_ms = 0;
    const output_silence_threshold_ms = 400; // Consider output "stopped" after 400ms of silence

    var led = LEDController.init();
    defer led.deinit();
    var logger = DebugLogger.init();
    defer logger.deinit();

    // Make stdin raw for proper terminal handling (only if stdin is a TTY)
    var original_termios: c.termios = undefined;
    const stdin_is_tty = c.isatty(posix.STDIN_FILENO) == 1;

    if (stdin_is_tty) {
        _ = c.tcgetattr(posix.STDIN_FILENO, &original_termios);
        var raw_termios = original_termios;
        c.cfmakeraw(&raw_termios);
        _ = c.tcsetattr(posix.STDIN_FILENO, c.TCSANOW, &raw_termios);
    }

    led.setState(current_state, &logger);
    logger.log("[DEBUG] Starting with timing-first approach: silence_threshold={d}ms\n", .{output_silence_threshold_ms});

    // Setup poll fds - only monitor stdin if it's a TTY
    var poll_fds: [2]posix.pollfd = undefined;
    poll_fds[0] = .{ .fd = pty.master, .events = posix.POLL.IN, .revents = 0 };
    const poll_fds_count: usize = if (stdin_is_tty) blk: {
        poll_fds[1] = .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 };
        break :blk 2;
    } else 1;

    var child_exit_status: ?posix.WaitPidResult = null;

    while (true) {
        const poll_result = posix.poll(poll_fds[0..poll_fds_count], 100) catch continue;

        // TIMING-FIRST: When no new data, check if we should change state based on silence
        if (poll_result == 0) {
            const now = std.time.milliTimestamp();
            const time_since_output = now - last_output_time;
            const time_in_current_state = now - last_state_change;

            // If output has been silent for > threshold, check patterns
            if (time_since_output > output_silence_threshold_ms and time_in_current_state >= min_state_duration_ms) {
                logger.log("[DEBUG] Silence detected: {d}ms since last output (threshold={d}ms)\n", .{ time_since_output, output_silence_threshold_ms });
                // Check last 20 lines for waiting patterns
                const check_line_count = @min(20, line_buffer.items.len);
                var found_waiting = false;

                if (check_line_count > 0) {
                    const start_idx = line_buffer.items.len - check_line_count;
                    for (line_buffer.items[start_idx..]) |line| {
                        for (matcher.waiting_patterns) |*pattern| {
                            if (try pattern.matches(line)) {
                                found_waiting = true;
                                logger.log("[DEBUG] Silence > {d}ms: Found waiting pattern '{s}' in recent lines\n", .{ time_since_output, pattern.pattern });
                                break;
                            }
                        }
                        if (found_waiting) break;
                    }
                }

                const new_state: State = if (found_waiting) .waiting else .idle;

                if (new_state != current_state) {
                    logger.log("[DEBUG] State change (silence): {s} -> {s} (silence={d}ms)\n", .{
                        @tagName(current_state),
                        @tagName(new_state),
                        time_since_output,
                    });
                    current_state = new_state;
                    last_state_change = now;
                    led.setState(current_state, &logger);
                }
            }
        }

        if (poll_result > 0) {
            // Check for PTY output
            if (poll_fds[0].revents & posix.POLL.IN != 0) {
                const n = posix.read(pty.master, &buffer) catch break;
                if (n == 0) break;

                _ = posix.write(posix.STDOUT_FILENO, buffer[0..n]) catch {};

                // Add output to line buffer
                const data = buffer[0..n];
                var line_start: usize = 0;
                for (data, 0..) |byte, i| {
                    if (byte == '\n') {
                        const line = try allocator.dupe(u8, data[line_start .. i + 1]);
                        try line_buffer.append(line);
                        total_buffer_bytes += line.len;
                        line_start = i + 1;

                        // Trim old lines if we exceed limits
                        while (line_buffer.items.len > max_lines or total_buffer_bytes > max_buffer_bytes) {
                            const old_line = line_buffer.orderedRemove(0);
                            total_buffer_bytes -= old_line.len;
                            allocator.free(old_line);
                        }
                    }
                }
                // Handle partial line at end
                if (line_start < data.len) {
                    const partial = try allocator.dupe(u8, data[line_start..]);
                    try line_buffer.append(partial);
                    total_buffer_bytes += partial.len;
                }

                // Update last output time
                const now = std.time.milliTimestamp();
                const time_since_last = now - last_output_time;
                const time_since_start = now - last_state_change;
                last_output_time = now;

                // Debug: log ALL output with timing to understand when it arrives
                logger.log("[DEBUG] OUTPUT: {d} bytes at +{d}ms (gap={d}ms, state={s})\n", .{
                    n,
                    time_since_start,
                    time_since_last,
                    @tagName(current_state),
                });

                // Check if this output contains thinking patterns
                var found_thinking = false;
                const text = buffer[0..n];
                logger.log("[DEBUG] Text to match: {s}\n", .{text});
                for (matcher.thinking_patterns) |*pattern| {
                    logger.log("[DEBUG] Pattern: {s}\n", .{pattern.pattern});
                    if (try pattern.matches(text)) {
                        found_thinking = true;
                        last_thinking_pattern_time = now;
                        logger.log("[DEBUG] Thinking pattern matched: {s}\n", .{pattern.pattern});
                        break;
                    }
                }
                logger.log("[DEBUG] Checking thinking patterns: found={}\n", .{found_thinking});

                // Only go to thinking if we found a thinking pattern
                if (found_thinking and current_state != .thinking) {
                    const time_in_state = now - last_state_change;
                    if (time_in_state >= min_state_duration_ms) {
                        logger.log("[DEBUG] State change (thinking pattern found): {s} -> thinking\n", .{@tagName(current_state)});
                        current_state = .thinking;
                        last_state_change = now;
                        led.setState(current_state, &logger);
                    }
                }

                // If we're thinking but haven't seen a thinking pattern in a while, go back to idle/waiting
                if (current_state == .thinking and !found_thinking) {
                    const time_since_thinking_pattern = now - last_thinking_pattern_time;
                    const time_in_state = now - last_state_change;

                    if (time_since_thinking_pattern > output_silence_threshold_ms and time_in_state >= min_state_duration_ms) {
                        logger.log("[DEBUG] No thinking pattern for {d}ms, checking for waiting/idle\n", .{time_since_thinking_pattern});

                        // Check last 20 lines for waiting patterns
                        const check_line_count = @min(20, line_buffer.items.len);
                        var found_waiting = false;

                        if (check_line_count > 0) {
                            const start_idx = line_buffer.items.len - check_line_count;
                            for (line_buffer.items[start_idx..]) |line| {
                                for (matcher.waiting_patterns) |*pattern| {
                                    if (try pattern.matches(line)) {
                                        found_waiting = true;
                                        break;
                                    }
                                }
                                if (found_waiting) break;
                            }
                        }

                        const new_state: State = if (found_waiting) .waiting else .idle;
                        logger.log("[DEBUG] State change (no thinking pattern): thinking -> {s}\n", .{@tagName(new_state)});
                        current_state = new_state;
                        last_state_change = now;
                        led.setState(current_state, &logger);
                    }
                }
            }

            // Check for stdin input (only if stdin is a TTY)
            if (stdin_is_tty and poll_fds[1].revents & posix.POLL.IN != 0) {
                const n = posix.read(posix.STDIN_FILENO, &buffer) catch break;
                if (n == 0) break;
                _ = posix.write(pty.master, buffer[0..n]) catch {};
            }

            // Check for HUP (child terminated)
            if (poll_fds[0].revents & posix.POLL.HUP != 0) {
                break;
            }
        }

        // Check if child process has exited
        const child_status = posix.waitpid(pid, posix.W.NOHANG);
        if (child_status.pid == pid) {
            // Child has exited
            child_exit_status = child_status;
            break;
        }
    }

    // Wait for child to exit (if it hasn't already)
    const result = child_exit_status orelse posix.waitpid(pid, 0);
    const exit_code = posix.W.EXITSTATUS(result.status);

    // Turn off LED when done (matches Python: subprocess.run([LED_SCRIPT, "o"]))
    led.turnOff(&logger);

    // Restore terminal before exiting (only if we set it to raw mode)
    if (stdin_is_tty) {
        _ = c.tcsetattr(posix.STDIN_FILENO, c.TCSADRAIN, &original_termios);
    }

    process.exit(exit_code);
}
