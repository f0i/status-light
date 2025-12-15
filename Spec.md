# SL - Status LED Command Wrapper

## Overview
SL (Status LED) is a Python-based command wrapper that monitors the output of any command-line tool and provides real-time visual feedback through LED indicators. It acts as a PTY (pseudo-terminal) wrapper that intercepts and analyzes stdout/stderr to determine the current state of the wrapped process, then controls LED lights accordingly.

## Purpose
The tool provides visual feedback for long-running command-line operations by changing LED colors based on the command's state:
- **Idle** (Blue): No activity detected
- **Thinking** (Yellow): Command is processing
- **Waiting** (Red): Command is waiting for input or resources

## Architecture

### Components

#### 1. sl.py (Main Application)
The Python wrapper that:
- Creates a PTY to monitor command output
- Analyzes output using configurable regex patterns
- Controls LED state via the `led` script
- Manages state transitions with debouncing

#### 2. led (LED Controller Script)
A bash script that communicates with LED hardware via serial interface (`/dev/ttyACM0`).

### Key Features

#### State Management
- **Three states**: idle, thinking, waiting
- **Minimum state duration**: 200ms to prevent flickering
- **Idle threshold**: Configurable (default 500ms)
- State changes are debounced to avoid rapid LED flashing

#### Configuration System
- YAML-based configuration files stored in `configs/` directory
- Per-tool configuration: `configs/<tool_name>.yaml`
- Fallback to `configs/default.yaml`
- Default built-in configuration if no files found

#### Pattern Matching
Configuration files define regex patterns to detect states:
```yaml
patterns:
  waiting:
    - "pattern1"
    - "pattern2"
  thinking:
    - "pattern3"
idle_threshold_ms: 500
```

## Technical Details

### PTY Wrapper Implementation
```python
# Opens pseudo-terminal to intercept I/O
master_fd, slave_fd = pty.openpty()
proc = subprocess.Popen(tool_cmd, stdin=slave_fd, stdout=slave_fd, stderr=slave_fd)
```

### Output Monitoring
- Uses `select.select()` with 100ms timeout for non-blocking reads
- Maintains 1KB rolling buffer of recent output
- Real-time pattern matching against buffer content
- Forwards all output to stdout transparently

### LED Control
LED colors are mapped to states:
```python
STATE_TO_CMD = {
    "idle": ["a", "0", "0", "255"],        # RGB: blue
    "thinking": ["a", "255", "255", "0"],  # RGB: yellow
    "waiting": ["a", "255", "0", "0"],     # RGB: red
}
```

### State Transition Logic
1. Output detected → Check waiting patterns first
2. If no waiting patterns match → Check thinking patterns
3. No output for idle_threshold_ms → Switch to idle
4. Process exits → Return to idle
5. All transitions respect MIN_STATE_DURATION (200ms)

## Usage

### Basic Command
```bash
./sl.py <command> [args...]
```

### Examples
```bash
# Monitor a build process
./sl.py make build

# Monitor a test suite
./sl.py pytest tests/

# Monitor a long-running script
./sl.py python my_script.py
```

## LED Script Interface

### Commands
- `a` (all): Set all LEDs to specified RGB color
- `o` (off): Turn off all LEDs
- `c`: Control individual LED
- `p`: Power command

### Protocol Format
```bash
a <R> <G> <B> <gamma>
```
Where R, G, B are 0-255 RGB values.

## Configuration Structure

### Directory Layout
```
/workspace/
├── sl.py              # Main wrapper script
├── led                # LED hardware controller
├── configs/           # Configuration directory
│   ├── default.yaml   # Default patterns
│   └── <tool>.yaml    # Tool-specific configs
└── .gitignore
```

### Sample Configuration
```yaml
patterns:
  waiting:
    - "Waiting for.*"
    - "\\[WAIT\\]"
    - "Press any key"
  thinking:
    - "Processing"
    - "Analyzing"
    - "Building"
idle_threshold_ms: 500
```

## Dependencies

### Python Modules
- `os`: File system operations
- `pty`: Pseudo-terminal creation
- `select`: Non-blocking I/O
- `subprocess`: Process management
- `sys`: System parameters and stdout
- `re`: Regular expression matching
- `time`: Timing and delays
- `yaml`: Configuration file parsing

### External Requirements
- Python 3.x
- PyYAML library
- Serial device at `/dev/ttyACM0` (for LED hardware)
- LED controller hardware compatible with the protocol

## Performance Characteristics

### Timing
- Select timeout: 100ms
- Minimum state duration: 200ms (anti-flicker)
- Default idle threshold: 500ms
- Read buffer: 1024 bytes per iteration

### Resource Usage
- Maintains 1KB rolling buffer
- Regex matching on every read
- Serial communication for state changes only
- PTY overhead for I/O interception

## Error Handling
- Missing configuration files → Falls back to default
- Missing default.yaml → Uses built-in defaults
- OSError on PTY read → Gracefully exits
- Process termination → Returns to idle state

## Limitations
- Requires serial LED hardware at `/dev/ttyACM0`
- Pattern matching limited to last 1KB of output
- 200ms minimum between state changes
- No support for multiple concurrent processes
- Assumes UTF-8 compatible output

## Future Enhancements
- Support for custom LED hardware interfaces
- Configurable buffer sizes
- Multiple LED pattern support
- State history and logging
- Web-based configuration UI
- Support for multiple simultaneous commands
