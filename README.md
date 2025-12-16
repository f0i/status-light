# SL - Status LED Command Wrapper

Physical LED status indicator for AI coding agents and CLI tools. Know when it's thinking vs waiting for input without checking the terminal.

## Overview

SL (Status LED) wraps any command-line tool and provides real-time visual feedback through RGB LED indicators. Perfect for monitoring AI coding agents (Claude Code, Aider, Cursor, etc.), builds, tests, and other long-running commands.

Available in two implementations:
- **Python** (`sl.py`) - Easy to modify, uses YAML configs
- **Zig** (`zig-out/bin/sl`) - Single binary, zero runtime dependencies, uses JSON configs

LED color states:

- 🔵 **Blue (Idle)**: No activity or waiting for next command
- 🟡 **Yellow (Thinking)**: Processing, building, compiling, running
- 🔴 **Red (Waiting)**: Waiting for input, resources, or confirmation

## Features

- **Universal wrapper**: Works with any command-line tool
- **Pattern-based detection**: Configurable regex patterns to detect states
- **Anti-flicker protection**: Minimum state duration prevents LED flashing
- **Per-tool configuration**: Custom patterns for different tools
- **Zero-intrusion**: Transparently passes through all I/O

## Requirements

### Python Version
- Python 3.x
- PyYAML library (`python3-yaml` package)
- LED hardware connected to `/dev/ttyACM0` (optional for testing)
- Linux environment

### Zig Version
- Zig 0.13.0+ (for building from source)
- LED hardware connected to `/dev/ttyACM0` (optional for testing)
- Linux environment

The compiled Zig binary has **zero runtime dependencies** - just copy and run.

## Installation

### Python Version

```bash
# Install Python YAML library
sudo apt install python3-yaml

# Make scripts executable
chmod +x sl.py led test_script.sh
```

### Zig Version

```bash
# Install Zig (if not already installed)
./dev/setup/zig.sh

# Build the binary
zig build

# The binary is now at: zig-out/bin/sl
# Copy it anywhere you want - it's a self-contained executable
cp zig-out/bin/sl /usr/local/bin/sl  # Optional: install system-wide
```

## Usage

### Basic Syntax

```bash
# Python version
./sl.py <command> [args...]

# Zig version
./zig-out/bin/sl <command> [args...]
```

### Examples

```bash
# Monitor AI coding agents
./sl.py claude              # Claude Code
./sl.py aider               # Aider
zig-out/bin/sl cursor       # Cursor (using Zig binary)

# Monitor builds and tests
./sl.py make build
./sl.py cargo test
./sl.py npm run build

# Monitor any long-running command
./sl.py ./your_script.sh

# Run the included test script
./sl.py ./test_script.sh
```

## Configuration

### Directory Structure

```
/workspace/
├── sl.py                      # Python wrapper script
├── src/main.zig              # Zig source code
├── build.zig                 # Zig build configuration
├── zig-out/bin/sl            # Compiled Zig binary
├── led                        # LED hardware controller
├── test_script.sh            # Demo/test script
├── configs/
│   ├── default.yaml          # Default patterns (Python)
│   ├── default.json          # Default patterns (Zig)
│   ├── claude.yaml           # Claude Code config (Python)
│   ├── claude.json           # Claude Code config (Zig)
│   └── <tool_name>.[yaml|json]  # Tool-specific configs
```

### Configuration Files

**Python version** uses YAML files:
1. `configs/<command_name>.yaml` - Tool-specific config
2. `configs/default.yaml` - Fallback config
3. Built-in defaults - If no files exist

**Zig version** uses JSON files:
1. `configs/<command_name>.json` - Tool-specific config
2. `configs/default.json` - Fallback config
3. Built-in defaults - If no files exist

### Configuration Format

**YAML (Python):**
```yaml
patterns:
  # Patterns that trigger waiting state (RED LED)
  waiting:
    - "\\[WAIT\\]"
    - "Waiting for"
    - "confirmation"
    - "\\(y/n\\)"

  # Patterns that trigger thinking state (YELLOW LED)
  thinking:
    - "\\[BUILD\\]"
    - "\\[TEST\\]"
    - "Processing"
    - "Compiling"
    - "Running"

# Time in ms before switching to idle
idle_threshold_ms: 500
```

**JSON (Zig):**
```json
{
  "patterns": {
    "waiting": [
      "\\[WAIT\\]",
      "Waiting for",
      "confirmation",
      "\\(y/n\\)"
    ],
    "thinking": [
      "\\[BUILD\\]",
      "\\[TEST\\]",
      "Processing",
      "Compiling",
      "Running"
    ]
  },
  "idle_threshold_ms": 500
}
```

### Creating Custom Configurations

1. Create a file in `configs/` named after your command
2. Define regex patterns for waiting and thinking states
3. Adjust idle threshold if needed

Example for a command called `myapp`:

**YAML (for Python):**
```bash
cat > configs/myapp.yaml << 'EOF'
patterns:
  waiting:
    - "User input required"
    - "Paused"
  thinking:
    - "Processing"
    - "Loading"
idle_threshold_ms: 1000
EOF

./sl.py myapp
```

**JSON (for Zig):**
```bash
cat > configs/myapp.json << 'EOF'
{
  "patterns": {
    "waiting": ["User input required", "Paused"],
    "thinking": ["Processing", "Loading"]
  },
  "idle_threshold_ms": 1000
}
EOF

zig-out/bin/sl myapp
```

## Testing

Run the included test script to see all LED states in action:

```bash
./sl.py ./test_script.sh
```

The test script demonstrates:
- Multiple stages with different output patterns
- State transitions between idle, thinking, and waiting
- Typical build/test/deploy workflow simulation

## How It Works

1. **PTY Wrapper**: Creates a pseudo-terminal to intercept command I/O
2. **Pattern Matching**: Analyzes output using regex patterns from config
3. **State Detection**: Matches patterns to determine current state
4. **LED Control**: Sends commands to LED hardware via serial
5. **Debouncing**: Prevents rapid state changes with minimum duration

### LED Command Format

The `led` script sends commands to the hardware:

```bash
a <R> <G> <B> <gamma>
```

- `a` = all LEDs
- R, G, B = Color values (0-255)
- gamma = Brightness (0-255)

### State Mapping

| State    | RGB Values      | Color  |
|----------|-----------------|--------|
| Idle     | 0, 0, 255       | Blue   |
| Thinking | 255, 255, 0     | Yellow |
| Waiting  | 255, 0, 0       | Red    |

## Technical Details

- **Buffer**: Maintains 1KB rolling buffer of recent output
- **Select timeout**: 100ms for non-blocking I/O
- **Min state duration**: 200ms to prevent flicker
- **Default idle threshold**: 500ms

For detailed technical documentation, see [Spec.md](Spec.md).

## Troubleshooting

### Python: ModuleNotFoundError: No module named 'yaml'

Install the PyYAML library:
```bash
sudo apt install python3-yaml
```

### Zig: Build errors

Make sure you have Zig 0.13.0 or newer:
```bash
zig version
```

### LED hardware not found

If `/dev/ttyACM0` doesn't exist, the LED commands won't work but the wrapper will still function and output the commands to stdout. This is normal for testing without hardware.

### Patterns not matching

- Check your regex patterns are properly escaped (e.g., `\\[` for literal `[`)
- Test patterns with the default config first
- Verify the config file is valid YAML/JSON
- Check the command name matches the config filename
- For Python: use `.yaml` files
- For Zig: use `.json` files

## Project Structure

```
.
├── README.md                  # This file
├── LICENSE                    # MIT License
├── Spec.md                   # Detailed technical specification
├── sl.py                     # Python implementation
├── src/
│   └── main.zig              # Zig implementation
├── build.zig                 # Zig build configuration
├── zig-out/bin/sl            # Compiled Zig binary
├── led                       # LED controller script (Bash)
├── test_script.sh            # Test/demo script
├── configs/
│   ├── default.yaml          # Default patterns (Python)
│   ├── default.json          # Default patterns (Zig)
│   ├── claude.yaml           # Claude Code config (Python)
│   ├── claude.json           # Claude Code config (Zig)
│   └── test_script.sh.*      # Test script configs
└── dev/setup/
    └── zig.sh                # Zig installation script
```

## Implementation Comparison

| Feature | Python (`sl.py`) | Zig (`zig-out/bin/sl`) |
|---------|------------------|------------------------|
| Runtime dependencies | Python 3, PyYAML | None (static binary) |
| Config format | YAML | JSON |
| Binary size | N/A | ~2.8MB |
| Installation | System Python | Copy binary anywhere |
| Modification | Edit `sl.py` | Rebuild from source |
| Startup time | ~50ms | ~1ms |

## Contributing

To add support for a new tool:

1. Identify output patterns for waiting and thinking states
2. Create a config file:
   - Python: `configs/<tool_name>.yaml`
   - Zig: `configs/<tool_name>.json`
3. Test with: `./sl.py <tool_name>` or `zig-out/bin/sl <tool_name>`
4. Adjust patterns and thresholds as needed

## License

See LICENSE file for details.

## See Also

- [Spec.md](Spec.md) - Detailed technical specification
- [test_script.sh](test_script.sh) - Example test script with patterns
- [configs/](configs/) - Configuration examples
