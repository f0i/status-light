# Agent Development Guide

This document helps AI coding agents get started working on the SL (Status LED) project.

## Project Overview

SL is a command wrapper that monitors CLI output and controls RGB LEDs based on detected state. Two implementations exist:
- **Python** (`sl.py`) - Prototype, uses YAML configs
- **Zig** (`src/main.zig`) - Production, uses JSON configs, zero deps

**Core concept:** Wrap any CLI tool, use regex patterns to detect states (idle/thinking/waiting), change LED colors accordingly.

**Target use case:** Visual feedback for AI coding agents and long-running CLI tools.

## Quick Start for Agents

### Understanding the Architecture

1. **PTY wrapper** - Creates pseudo-terminal to intercept I/O
2. **Pattern matcher** - Regex against rolling output buffer
3. **State machine** - Three states with debouncing (200ms minimum)
4. **LED controller** - Serial commands to `/dev/ttyACM0`

### Key Files

```
sl.py              # Python impl - start here for quick changes
src/main.zig       # Zig impl - for performance/distribution
configs/           # Pattern definitions
  claude.{yaml,json}    # Example: AI coding agent patterns
  default.{yaml,json}   # Fallback patterns
led                # LED hardware controller script
test_script.sh     # Test various state transitions
```

### Common Tasks

#### 1. Adding Support for a New Tool

**Example:** Adding support for a new AI agent called "codex"

```bash
# 1. Observe the tool's output patterns
codex task.txt | tee output.txt

# 2. Identify state indicators
# - Waiting: "Enter your choice:", "Press any key", etc.
# - Thinking: "Analyzing...", "Generating...", etc.

# 3. Create config (JSON for Zig, YAML for Python)
cat > configs/codex.json << 'EOF'
{
  "patterns": {
    "waiting": [
      "Enter your choice",
      "Press any key",
      "\\[Y/n\\]"
    ],
    "thinking": [
      "Analyzing",
      "Generating",
      "Processing"
    ]
  },
  "idle_threshold_ms": 500
}
EOF

# 4. Test it
./zig-out/bin/sl codex task.txt
```

**Pro tip:** Start with overly specific patterns, then generalize. Better to miss states than false positive.

#### 2. Debugging Pattern Matching

**Python version** has DEBUG mode:
```bash
DEBUG_SL=1 ./sl.py your-command
```

This shows:
- Buffer contents (last 200 chars)
- Which patterns matched
- State transitions

**Common issues:**
- **Patterns too broad** - Match unintended output
- **Patterns too specific** - Miss valid states
- **Wrong escaping** - Remember `\\[` for literal `[`
- **Timing issues** - Adjust `idle_threshold_ms`

#### 3. Improving Pattern Detection

The Python implementation uses two buffer strategies:

```python
tail_lines = '\n'.join(lines[-10:])  # Last 10 lines for UI/prompt patterns
full_buffer = text                    # Entire 1KB buffer for thinking indicators
```

**Rationale:**
- **Waiting patterns** (prompts) appear at the end of output
- **Thinking patterns** (progress indicators) can appear anywhere

When adding patterns, consider which buffer makes sense:
- User prompts → `waiting` (checks tail lines)
- Build/test output → `thinking` (checks full buffer)

## Pattern Writing Best Practices

### 1. Escape Special Characters

```yaml
# BAD
waiting:
  - "[y/n]"      # Matches any char in y/n

# GOOD
waiting:
  - "\\[y/n\\]"  # Matches literal [y/n]
```

### 2. Use Anchors Sparingly

```yaml
# Usually avoid ^ and $ because output is buffered
# BAD
waiting:
  - "^Enter your choice$"

# GOOD (matches anywhere in buffer)
waiting:
  - "Enter your choice"
```

### 3. Match Partial Words for Robustness

```yaml
# GOOD - catches "compiling", "Compiling", "COMPILING"
thinking:
  - "ompil"     # Matches compile/compiling/compiler
  - "uild"      # Matches build/building/built
```

### 4. Handle ANSI Escape Codes

Many tools use colored output. Some patterns in `claude.json`:

```json
"\\x1b\\[96m●\\x1b\\[39m"  // Cyan colored bullet
```

**Tip:** Use DEBUG_SL=1 to see raw output with escape codes.

## Testing

### Manual Testing

```bash
# Test with included test script
./sl.py ./test_script.sh

# Watch for state transitions:
# IDLE (blue) → THINKING (yellow) → WAITING (red) → back to IDLE
```

### Without Hardware

LED hardware is optional. Without `/dev/ttyACM0`, commands print to stdout:
```
a 0 0 255 64    # Blue (idle)
a 255 255 0 64  # Yellow (thinking)
a 255 0 0 64    # Red (waiting)
```

### Writing Good Test Scripts

See `test_script.sh` for examples:

```bash
# Trigger THINKING state
echo "[BUILD] Compiling..."
sleep 2

# Trigger WAITING state
echo "[WAIT] Press enter to continue"
read

# Return to IDLE automatically after idle_threshold_ms
```

## Zig Development

### Building

```bash
zig build          # Build debug
zig build -Doptimize=ReleaseFast  # Build optimized
```

### Key Differences from Python

| Aspect | Python | Zig |
|--------|--------|-----|
| Config parsing | PyYAML | std.json |
| Regex | Python re | POSIX regex (via C) |
| Memory | GC | Manual allocation |
| Pattern storage | Lists | Allocated slices |

### Zig Pattern Matching

```zig
// CompiledPattern stores regex_t in fixed-size buffer
regex_storage: [512]u8 align(@alignOf(c_longlong))

// Compile pattern using POSIX regex
c.regcomp(regex_ptr, c_pattern, c.REG_EXTENDED | c.REG_NOSUB)

// Match against text
c.regexec(regex_ptr, c_text, 0, null, 0)
```

**Important:** Zig uses POSIX extended regex, not PCRE. Some differences:
- No `\d` shorthand (use `[0-9]`)
- No lookahead/lookbehind
- No non-greedy quantifiers

## Common Pitfalls

### 1. Regex Syntax Between Languages

**Python (PCRE-like):**
```yaml
thinking:
  - "\\d+%"        # \d for digit
```

**Zig (POSIX):**
```json
"thinking": [
  "[0-9]+%"        # [0-9] for digit
]
```

### 2. State Debouncing

Both implementations have 200ms minimum state duration. This prevents LED flickering but means very fast state changes are ignored.

**If states are missed:**
- Decrease `idle_threshold_ms` in config
- Check if patterns are too specific

### 3. Buffer Size Limits

Both implementations maintain 1KB rolling buffer. Very verbose output might overflow.

**Symptoms:**
- Important patterns scroll out of buffer
- State detection becomes unreliable

**Solutions:**
- Use more distinctive patterns
- Match on recently appeared text (see tail_lines approach)

### 4. UTF-8 and Special Characters

Both implementations handle UTF-8, but pattern files must be UTF-8 encoded.

**Example from claude.json:**
```json
"❯"              # Unicode arrow (U+276F)
"[✶✸✹✺✻✼✽✾✿]"  # Star characters
```

Make sure your editor saves configs as UTF-8.

## Architecture Notes

### Why Two Implementations?

**Python** - Fast iteration:
- Modify patterns without recompiling
- Easy to add debug output
- Good for prototyping new features

**Zig** - Production deployment:
- Single ~2.8MB binary
- No Python/PyYAML dependency
- Faster startup (matters for short commands)
- Can distribute to any Linux system

### State Machine

```
        ┌─────┐
   ┌───▶│IDLE │◀───┐
   │    └─────┘    │
   │       ▲       │
   │       │       │
no │       │no     │ idle_timeout
output     │output │
   │       │       │
   │    ┌──┴───┐   │
   └────│THINK │───┘
   │    └──┬───┘
   │       │
   │       │waiting
   │       │pattern
   │       │
   │    ┌──▼───┐
   └────│ WAIT │
        └──────┘
```

**Rules:**
- States can only change after 200ms minimum duration
- WAITING patterns checked first (higher priority)
- THINKING patterns checked only if not waiting
- Idle timeout only applies to THINKING state (not WAITING)

### LED Protocol

Serial commands to `/dev/ttyACM0` at 115200 baud:

```
a <R> <G> <B> <gamma>\n
```

- `a` = all LEDs (single character command)
- R, G, B = 0-255
- gamma = brightness 0-255 (typically 64)

See `led` script for implementation.

## Tips for AI Agents

### When Adding Features

1. **Start with Python** - Prototype in `sl.py`
2. **Test thoroughly** - Use `DEBUG_SL=1`
3. **Port to Zig** - Once proven, add to `src/main.zig`
4. **Update configs** - Keep YAML and JSON in sync

### When Fixing Bugs

1. **Reproduce first** - Create minimal test case
2. **Check both implementations** - Bug might exist in both
3. **Update tests** - Add case to `test_script.sh` if appropriate

### When Adding Tool Support

1. **Observe before coding** - Run tool, capture output
2. **Identify unique patterns** - What reliably indicates each state?
3. **Test edge cases** - Very fast output, very slow output, errors
4. **Document in config** - Add comments explaining pattern choices

### Git Workflow

```bash
# Check what's changed
git status

# Commit logical units
git add configs/newtool.json
git commit -m "Add config for newtool"

# Build artifacts are ignored (.zig-cache/, zig-out/)
# Dev folder is ignored (dev/)
```

## Resources

- **Spec.md** - Detailed technical specification
- **README.md** - User-facing documentation
- **test_script.sh** - Example state transitions
- **configs/claude.json** - Complex real-world patterns

## Questions?

Read the code - both implementations are ~400 lines total and well-commented. The architecture is intentionally simple.
