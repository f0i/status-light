const std = @import("std");
const os = std.os;
const fs = std.fs;
const process = std.process;
const posix = std.posix;

const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("termios.h");
    @cInclude("pty.h");
    @cInclude("regex.h");
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
        // Format matches led script output: "a <r> <g> <b> <gamma>" (4 values)
        // led script uses: printf "a %03d %03d %03d %03d\n" $r $g $b $gamma
        const cmd = switch (state) {
            .idle => "a 000 000 255 255\n", // Blue: R=0, G=0, B=255, gamma=255
            .thinking => "a 255 255 000 255\n", // Yellow: R=255, G=255, B=0, gamma=255
            .waiting => "a 100 000 000 255\n", // Dim Red: R=100, G=0, B=0, gamma=255
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
    // Use byte array as storage for opaque regex_t
    // regex_t is typically around 32-64 bytes on most platforms
    regex_storage: [512]u8 align(@alignOf(c_longlong)),
    pattern: []const u8,
    allocator: std.mem.Allocator,

    fn compile(allocator: std.mem.Allocator, pattern: []const u8) !CompiledPattern {
        var self: CompiledPattern = undefined;
        self.allocator = allocator;
        self.pattern = try allocator.dupe(u8, pattern);
        errdefer allocator.free(self.pattern);

        const c_pattern = try allocator.dupeZ(u8, pattern);
        defer allocator.free(c_pattern);

        const regex_ptr: *c.regex_t = @ptrCast(@alignCast(&self.regex_storage));
        const result = c.regcomp(regex_ptr, c_pattern, c.REG_EXTENDED | c.REG_NOSUB);
        if (result != 0) {
            allocator.free(self.pattern);
            return error.RegexCompileError;
        }

        return self;
    }

    fn deinit(self: *CompiledPattern) void {
        const regex_ptr: *c.regex_t = @ptrCast(@alignCast(&self.regex_storage));
        c.regfree(regex_ptr);
        self.allocator.free(self.pattern);
    }

    fn matches(self: *const CompiledPattern, text: []const u8) !bool {
        const c_text = try self.allocator.dupeZ(u8, text);
        defer self.allocator.free(c_text);

        const regex_ptr: *const c.regex_t = @ptrCast(@alignCast(&self.regex_storage));
        const result = c.regexec(regex_ptr, c_text, 0, null, 0);
        return result == 0;
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
        for (self.thinking_patterns) |*pattern| {
            if (try pattern.matches(full_buffer)) {
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
    var config_result = try loadConfig(allocator, tool_name);
    defer config_result.deinit();

    var logger = DebugLogger.init();
    defer logger.deinit();

    var matcher = try PatternMatcher.init(allocator, config_result.config);
    defer matcher.deinit();

    var led = LEDController.init();
    defer led.deinit();

    // Open PTY
    const pty = try openPty();
    defer posix.close(pty.master);
    defer posix.close(pty.slave);

    // Make stdin raw for proper terminal handling (only if stdin is a TTY)
    var original_termios: c.termios = undefined;
    const stdin_is_tty = c.isatty(posix.STDIN_FILENO) == 1;

    if (stdin_is_tty) {
        _ = c.tcgetattr(posix.STDIN_FILENO, &original_termios);
        var raw_termios = original_termios;
        c.cfmakeraw(&raw_termios);
        _ = c.tcsetattr(posix.STDIN_FILENO, c.TCSANOW, &raw_termios);
    }

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

        const child_args = args[1..];

        // Build null-terminated argument array for exec
        var argv = try allocator.alloc(?[*:0]const u8, child_args.len + 1);
        defer allocator.free(argv);

        for (child_args, 0..) |arg, i| {
            argv[i] = (try allocator.dupeZ(u8, arg)).ptr;
        }
        argv[child_args.len] = null;

        // Use execvp which searches PATH and uses current environment
        const err = posix.execvpeZ(
            try allocator.dupeZ(u8, child_args[0]),
            @ptrCast(argv.ptr),
            @ptrCast(environ),
        );

        std.debug.print("execvpe failed: {}\n", .{err});
        process.exit(1);
    }

    // Parent process - monitor PTY
    var buffer: [1024]u8 = undefined;
    var rolling_buffer = std.ArrayList(u8).init(allocator);
    defer rolling_buffer.deinit();

    var current_state: State = .idle;
    var last_output_time = std.time.milliTimestamp();
    var last_state_change = std.time.milliTimestamp();
    const min_state_duration_ms = 200;

    led.setState(current_state, &logger);

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

        // Check idle timeout ONLY when there's no new data (matches Python: if not rlist)
        if (poll_result == 0) {
            const now = std.time.milliTimestamp();
            const time_since_output = now - last_output_time;
            const time_in_current_state = now - last_state_change;

            if (logger.file != null and current_state != .idle and time_since_output > 100) {
                logger.log("[DEBUG] Idle check (no data): state={s}, time_since_output={d}ms (threshold={d}ms), time_in_state={d}ms (min={d}ms)\n", .{
                    @tagName(current_state),
                    time_since_output,
                    config_result.config.idle_threshold_ms,
                    time_in_current_state,
                    min_state_duration_ms,
                });
            }

            // Only go idle if we're not in waiting state (matches Python behavior)
            // Use longer timeout for thinking state to avoid flickering (thinking->idle needs 2x threshold)
            const idle_threshold = if (current_state == .thinking)
                config_result.config.idle_threshold_ms * 2
            else
                config_result.config.idle_threshold_ms;

            if (current_state != .idle and current_state != .waiting and
                time_since_output > @as(i64, @intCast(idle_threshold)) and
                time_in_current_state >= min_state_duration_ms)
            {
                logger.log("[DEBUG] Going idle (no data): time_since_output={d}ms > threshold={d}ms (state={s})\n", .{
                    time_since_output,
                    idle_threshold,
                    @tagName(current_state),
                });
                current_state = .idle;
                last_state_change = now;
                led.setState(current_state, &logger);
            }
        }

        if (poll_result > 0) {
            // Check for PTY output
            if (poll_fds[0].revents & posix.POLL.IN != 0) {
                const n = posix.read(pty.master, &buffer) catch break;
                if (n == 0) break;

                _ = posix.write(posix.STDOUT_FILENO, buffer[0..n]) catch {};

                // Update rolling buffer (keep last 1KB)
                try rolling_buffer.appendSlice(buffer[0..n]);
                if (rolling_buffer.items.len > 1024) {
                    const excess = rolling_buffer.items.len - 1024;
                    std.mem.copyForwards(u8, rolling_buffer.items, rolling_buffer.items[excess..]);
                    rolling_buffer.shrinkRetainingCapacity(1024);
                }

                // Always update idle timer on ANY output (matches Python behavior)
                last_output_time = std.time.milliTimestamp();

                // Debug: Log buffer content (disabled to reduce log size)
                // Uncomment if needed for debugging
                //if (logger.file != null) {
                //    const text = rolling_buffer.items;
                //    logger.log("\n[DEBUG] Buffer: {s}\n", .{text[0..@min(100, text.len)]});
                //}

                // Pattern matching
                const text = rolling_buffer.items;
                if (try matcher.matchState(text, &logger)) |new_state| {
                    const now = std.time.milliTimestamp();
                    if (new_state != current_state and (now - last_state_change) >= min_state_duration_ms) {
                        logger.log("[DEBUG] State change: {s} -> {s} (time_in_state={d}ms)\n", .{
                            @tagName(current_state),
                            @tagName(new_state),
                            now - last_state_change,
                        });
                        current_state = new_state;
                        last_state_change = now;
                        led.setState(current_state, &logger);
                    } else if (new_state != current_state) {
                        logger.log("[DEBUG] State change blocked: {s} -> {s} (time_in_state={d}ms < min={d}ms)\n", .{
                            @tagName(current_state),
                            @tagName(new_state),
                            now - last_state_change,
                            min_state_duration_ms,
                        });
                    }
                } else {
                    logger.log("[DEBUG] No pattern match in buffer\n", .{});
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
        _ = c.tcsetattr(posix.STDIN_FILENO, c.TCSANOW, &original_termios);
    }

    process.exit(exit_code);
}
