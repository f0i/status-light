# SL - Status LED Command Wrapper

A Python-based command wrapper that provides real-time visual feedback through LED indicators by monitoring command-line tool output.

## Overview

SL (Status LED) wraps any command-line tool and changes LED colors based on what's happening:

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

- Python 3.x
- PyYAML library (`python3-yaml` package)
- LED hardware connected to `/dev/ttyACM0` (optional for testing)
- Linux environment

### Installation

```bash
# Install Python YAML library
sudo apt install python3-yaml

# Make scripts executable
chmod +x sl.py led test_script.sh
```

## Usage

### Basic Syntax

```bash
./sl.py <command> [args...]
```

### Examples

```bash
# Monitor a build process
./sl.py make build

# Monitor tests
./sl.py pytest tests/

# Monitor any long-running command
./sl.py ./your_script.sh

# Run the included test script
./sl.py ./test_script.sh
```

## Configuration

### Directory Structure

```
/workspace/
├── sl.py                      # Main wrapper script
├── led                        # LED hardware controller
├── test_script.sh            # Demo/test script
├── configs/
│   ├── default.yaml          # Fallback configuration
│   └── <tool_name>.yaml      # Tool-specific configs
```

### Configuration Files

Configurations are stored in the `configs/` directory as YAML files. The wrapper looks for:

1. `configs/<command_name>.yaml` - Tool-specific config
2. `configs/default.yaml` - Fallback config
3. Built-in defaults - If no files exist

### Configuration Format

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

### Creating Custom Configurations

1. Create a file in `configs/` named after your command
2. Define regex patterns for waiting and thinking states
3. Adjust idle threshold if needed

Example for a command called `myapp`:

```bash
# Create config file
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

# Run with config
./sl.py myapp
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

### ModuleNotFoundError: No module named 'yaml'

Install the PyYAML library:
```bash
sudo apt install python3-yaml
```

### LED hardware not found

If `/dev/ttyACM0` doesn't exist, the LED commands won't work but the wrapper will still function and output the commands to stdout. This is normal for testing without hardware.

### Patterns not matching

- Check your regex patterns are properly escaped (e.g., `\\[` for literal `[`)
- Test patterns with the default config first
- Verify the config file is valid YAML
- Check the command name matches the config filename

## Project Structure

```
.
├── README.md              # This file
├── Spec.md               # Detailed technical specification
├── sl.py                 # Main PTY wrapper (Python)
├── led                   # LED controller script (Bash)
├── test_script.sh        # Test/demo script
├── configs/
│   ├── default.yaml      # Default patterns
│   └── test_script.sh.yaml  # Test script config
└── .gitignore
```

## Contributing

To add support for a new tool:

1. Identify output patterns for waiting and thinking states
2. Create a config file: `configs/<tool_name>.yaml`
3. Test with: `./sl.py <tool_name>`
4. Adjust patterns and thresholds as needed

## License

See LICENSE file for details.

## See Also

- [Spec.md](Spec.md) - Detailed technical specification
- [test_script.sh](test_script.sh) - Example test script with patterns
- [configs/](configs/) - Configuration examples
