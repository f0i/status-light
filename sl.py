#!/usr/bin/env python3
import os
import pty
import select
import subprocess
import sys
import re
import time
import yaml

# ----------------------------
# Configuration
# ----------------------------
CONFIG_DIR = os.path.join(os.path.dirname(__file__), "configs")
MIN_STATE_DURATION = 0.2  # seconds to avoid flicker

STATE_TO_CMD = {
    "idle": ["a", "0", "0", "255"],        # blue
    "thinking": ["a", "255", "255", "0"],  # yellow
    "waiting": ["a", "255", "0", "0"],     # red
}

LED_SCRIPT = os.path.join(os.path.dirname(__file__), "led")

# ----------------------------
# Utility functions
# ----------------------------
def load_config(tool_name):
    try:
        with open(os.path.join(CONFIG_DIR, f"{tool_name}.yaml")) as f:
            return yaml.safe_load(f)
    except FileNotFoundError:
        try:
            with open(os.path.join(CONFIG_DIR, "default.yaml")) as f:
                return yaml.safe_load(f)
        except FileNotFoundError:
            return {"patterns": {}, "idle_threshold_ms": 500}

def set_led(state):
    args = STATE_TO_CMD.get(state, STATE_TO_CMD["idle"])
    cmd = [LED_SCRIPT] + args
    subprocess.run(cmd)

# ----------------------------
# Core PTY wrapper
# ----------------------------
def run_tool(tool_cmd, config):
    last_state = None
    last_change = 0

    def update_state(state):
        nonlocal last_state, last_change
        now = time.time()
        if state != last_state and now - last_change > MIN_STATE_DURATION:
            set_led(state)
            last_state = state
            last_change = now

    master_fd, slave_fd = pty.openpty()
    proc = subprocess.Popen(tool_cmd, stdin=slave_fd, stdout=slave_fd, stderr=slave_fd, close_fds=True)
    os.close(slave_fd)

    buffer = b""
    idle_timer = time.time()

    while True:
        rlist, _, _ = select.select([master_fd], [], [], 0.1)
        if master_fd in rlist:
            try:
                data = os.read(master_fd, 1024)
            except OSError:
                break
            if not data:
                break
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
            buffer += data
            idle_timer = time.time()

            text = buffer.decode(errors="ignore")
            # Check waiting patterns
            if any(re.search(p, text) for p in config.get("patterns", {}).get("waiting", [])):
                update_state("waiting")
            # Check thinking patterns
            elif any(re.search(p, text) for p in config.get("patterns", {}).get("thinking", [])):
                update_state("thinking")
            buffer = buffer[-1024:]  # keep last 1k bytes
        else:
            # no output, check for idle
            if (time.time() - idle_timer)*1000 > config.get("idle_threshold_ms", 500):
                update_state("idle")

        # check if process exited
        if proc.poll() is not None:
            update_state("idle")
            break

    proc.wait()

# ----------------------------
# CLI Entry
# ----------------------------
if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: sl <command> [args...]")
        sys.exit(1)

    tool_cmd = sys.argv[1:]
    tool_name = os.path.basename(tool_cmd[0])
    config = load_config(tool_name)

    run_tool(tool_cmd, config)

