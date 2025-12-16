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

    fn setState(self: *LEDController, state: State) void {
        const cmd = switch (state) {
            .idle => "a 0 0 255 64\n", // Blue
            .thinking => "a 255 255 0 64\n", // Yellow
            .waiting => "a 255 0 0 64\n", // Red
        };

        if (self.fd) |fd| {
            _ = posix.write(fd, cmd) catch |err| {
                std.debug.print("LED write error: {}\n", .{err});
            };
        } else {
            // No LED hardware, print to stdout for debugging
            std.debug.print("{s}", .{cmd});
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

    fn matchState(self: *const PatternMatcher, text: []const u8) !?State {
        // Check waiting patterns first (higher priority)
        for (self.waiting_patterns) |*pattern| {
            if (try pattern.matches(text)) {
                return .waiting;
            }
        }

        // Check thinking patterns
        for (self.thinking_patterns) |*pattern| {
            if (try pattern.matches(text)) {
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

    var matcher = try PatternMatcher.init(allocator, config_result.config);
    defer matcher.deinit();

    var led = LEDController.init();
    defer led.deinit();

    // Open PTY
    const pty = try openPty();
    defer posix.close(pty.master);
    defer posix.close(pty.slave);

    // Make stdin raw for proper terminal handling
    var original_termios: c.termios = undefined;
    _ = c.tcgetattr(posix.STDIN_FILENO, &original_termios);

    var raw_termios = original_termios;
    c.cfmakeraw(&raw_termios);
    _ = c.tcsetattr(posix.STDIN_FILENO, c.TCSANOW, &raw_termios);
    defer _ = c.tcsetattr(posix.STDIN_FILENO, c.TCSANOW, &original_termios);

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
            @ptrCast(&environ),
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

    led.setState(current_state);

    var poll_fds = [_]posix.pollfd{
        .{ .fd = pty.master, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
    };

    var child_exit_status: ?posix.WaitPidResult = null;

    while (true) {
        const poll_result = posix.poll(&poll_fds, 100) catch continue;

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

                last_output_time = std.time.milliTimestamp();

                // Pattern matching
                const text = rolling_buffer.items;
                if (try matcher.matchState(text)) |new_state| {
                    const now = std.time.milliTimestamp();
                    if (new_state != current_state and (now - last_state_change) >= min_state_duration_ms) {
                        current_state = new_state;
                        last_state_change = now;
                        led.setState(current_state);
                    }
                }
            }

            // Check for stdin input
            if (poll_fds[1].revents & posix.POLL.IN != 0) {
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

        // Check idle timeout
        const now = std.time.milliTimestamp();
        if (current_state != .idle and
            (now - last_output_time) > @as(i64, @intCast(config_result.config.idle_threshold_ms)) and
            (now - last_state_change) >= min_state_duration_ms)
        {
            current_state = .idle;
            last_state_change = now;
            led.setState(current_state);
        }
    }

    // Wait for child to exit (if it hasn't already)
    const result = child_exit_status orelse posix.waitpid(pid, 0);
    const exit_code = posix.W.EXITSTATUS(result.status);

    // Turn off LED when done
    led.setState(.idle);

    process.exit(exit_code);
}
