package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"time"

	"github.com/creack/pty"
	"golang.org/x/term"
)

type State int

const (
	Idle State = iota
	Thinking
	Waiting
)

func (s State) String() string {
	switch s {
	case Idle:
		return "idle"
	case Thinking:
		return "thinking"
	case Waiting:
		return "waiting"
	default:
		return "unknown"
	}
}

type Config struct {
	Patterns struct {
		Waiting  []string `json:"waiting"`
		Thinking []string `json:"thinking"`
	} `json:"patterns"`
	IdleThresholdMs int `json:"idle_threshold_ms"`
}

type LEDController struct {
	ledScript string
	debug     bool
}

func NewLEDController() *LEDController {
	exePath, _ := os.Executable()
	dir := filepath.Dir(exePath)
	return &LEDController{
		ledScript: filepath.Join(dir, "led"),
		debug:     os.Getenv("DEBUG_SL") != "",
	}
}

func (l *LEDController) SetState(state State) {
	// Match Python version exactly
	var args []string
	switch state {
	case Idle:
		args = []string{"a", "0", "0", "0", "255"} // blue
	case Thinking:
		args = []string{"a", "0", "255", "255", "0"} // yellow
	case Waiting:
		args = []string{"a", "0", "100", "0", "0"} // red
	}

	if l.debug {
		fmt.Fprintf(os.Stderr, "[DEBUG] LED State: %s -> ./led %v\n", state, args)
	}

	cmd := exec.Command(l.ledScript, args...)
	cmd.Stdout = nil
	cmd.Stderr = nil
	_ = cmd.Run()
}

func (l *LEDController) TurnOff() {
	if l.debug {
		fmt.Fprintf(os.Stderr, "[DEBUG] LED: turning off\n")
	}
	cmd := exec.Command(l.ledScript, "o")
	cmd.Stdout = nil
	cmd.Stderr = nil
	_ = cmd.Run()
}

func loadConfig(toolName string) Config {
	// Try loading config
	configPaths := []string{
		"configs/" + toolName + ".json",
		"configs/claude.json",
		"configs/default.json",
	}

	for _, path := range configPaths {
		if data, err := os.ReadFile(path); err == nil {
			var cfg Config
			if json.Unmarshal(data, &cfg) == nil {
				return cfg
			}
		}
	}

	// Default config
	return Config{
		Patterns: struct {
			Waiting  []string `json:"waiting"`
			Thinking []string `json:"thinking"`
		}{
			Waiting:  []string{"wait", "Wait", "\\(y/n\\)"},
			Thinking: []string{"Imagining", "imagining", "Running", "running"},
		},
		IdleThresholdMs: 500,
	}
}

func compilePatterns(patterns []string) []*regexp.Regexp {
	var compiled []*regexp.Regexp
	for _, p := range patterns {
		if re, err := regexp.Compile(p); err == nil {
			compiled = append(compiled, re)
		}
	}
	return compiled
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintf(os.Stderr, "Usage: %s <command> [args...]\n", os.Args[0])
		os.Exit(1)
	}

	debug := os.Getenv("DEBUG_SL") != ""
	toolName := filepath.Base(os.Args[1])
	cfg := loadConfig(toolName)
	waitingPatterns := compilePatterns(cfg.Patterns.Waiting)
	thinkingPatterns := compilePatterns(cfg.Patterns.Thinking)
	led := NewLEDController()

	if debug {
		fmt.Fprintf(os.Stderr, "[DEBUG] Thinking patterns: %d\n", len(thinkingPatterns))
		fmt.Fprintf(os.Stderr, "[DEBUG] Starting timing-first approach: silence_threshold=2000ms\n")
	}

	// Setup PTY
	cmd := exec.Command(os.Args[1], os.Args[2:]...)
	ptmx, err := pty.Start(cmd)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to start PTY: %v\n", err)
		os.Exit(1)
	}
	defer ptmx.Close()

	// Set raw mode if stdin is a TTY
	var oldState *term.State
	if term.IsTerminal(int(os.Stdin.Fd())) {
		oldState, _ = term.MakeRaw(int(os.Stdin.Fd()))
		if oldState != nil {
			defer term.Restore(int(os.Stdin.Fd()), oldState)
		}
	}

	// State tracking
	currentState := Idle
	lastOutputTime := time.Now()
	lastStateChange := time.Now()
	lineBuffer := make([]string, 0, 100)
	const minStateDuration = 200 * time.Millisecond
	const silenceThreshold = 500 * time.Millisecond

	led.SetState(currentState)

	// Channel for PTY output
	ptyOutput := make(chan []byte, 100)
	go func() {
		buf := make([]byte, 1024)
		for {
			n, err := ptmx.Read(buf)
			if err != nil {
				close(ptyOutput)
				return
			}
			data := make([]byte, n)
			copy(data, buf[:n])
			ptyOutput <- data
		}
	}()

	// Channel for stdin
	stdinChan := make(chan []byte, 10)
	if term.IsTerminal(int(os.Stdin.Fd())) {
		go func() {
			buf := make([]byte, 1024)
			for {
				n, err := os.Stdin.Read(buf)
				if err != nil {
					return
				}
				data := make([]byte, n)
				copy(data, buf[:n])
				stdinChan <- data
			}
		}()
	}

	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case data, ok := <-ptyOutput:
			if !ok {
				goto cleanup
			}

			// Write to stdout
			os.Stdout.Write(data)

			// Update line buffer
			for _, b := range data {
				if b == '\n' {
					if len(lineBuffer) >= 100 {
						lineBuffer = lineBuffer[1:]
					}
				}
			}
			lineBuffer = append(lineBuffer, string(data))
			if len(lineBuffer) > 100 {
				lineBuffer = lineBuffer[len(lineBuffer)-100:]
			}

			// Update timing
			now := time.Now()
			lastOutputTime = now

			// Check for thinking patterns in the output
			foundThinking := false
			outputStr := string(data)
			for _, pattern := range thinkingPatterns {
				if pattern.MatchString(outputStr) {
					foundThinking = true
					if debug {
						fmt.Fprintf(os.Stderr, "[DEBUG] Thinking pattern matched: %s\n", pattern.String())
					}
					break
				}
			}

			if foundThinking {
				if currentState != Thinking {
					if debug {
						fmt.Fprintf(os.Stderr, "[DEBUG] State change (thinking pattern): %s -> thinking\n", currentState)
					}
					currentState = Thinking
					lastStateChange = now
					led.SetState(currentState)
				}
			} else if debug {
				fmt.Fprintf(os.Stderr, "[DEBUG] No thinking patterns in output: %d bytes (state=%s)\n", len(data), currentState)
			}

		case data := <-stdinChan:
			ptmx.Write(data)

		case <-ticker.C:
			// Check for silence
			now := time.Now()
			timeSinceOutput := now.Sub(lastOutputTime)
			timeInState := now.Sub(lastStateChange)

			if timeSinceOutput > silenceThreshold && timeInState >= minStateDuration {
				// Check last 20 lines for waiting patterns
				foundWaiting := false
				checkCount := 20
				if len(lineBuffer) < checkCount {
					checkCount = len(lineBuffer)
				}

				if checkCount > 0 {
					startIdx := len(lineBuffer) - checkCount
					for i := startIdx; i < len(lineBuffer); i++ {
						for _, pattern := range waitingPatterns {
							if pattern.MatchString(lineBuffer[i]) {
								foundWaiting = true
								if debug {
									fmt.Fprintf(os.Stderr, "[DEBUG] Silence > %dms: Found waiting pattern in recent lines\n", int(timeSinceOutput.Milliseconds()))
								}
								break
							}
						}
						if foundWaiting {
							break
						}
					}
				}

				newState := Idle
				if foundWaiting {
					newState = Waiting
				}

				if newState != currentState {
	if debug {
		fmt.Fprintf(os.Stderr, "[DEBUG] Starting timing-first approach: silence_threshold=%dms\n", int(silenceThreshold.Milliseconds()))
	}
					currentState = newState
					lastStateChange = now
					led.SetState(currentState)
				}
			}
		}
	}

cleanup:
	// Wait for command to finish
	cmd.Wait()

	// Turn off LED immediately
	led.TurnOff()

	// Restore terminal
	if oldState != nil {
		term.Restore(int(os.Stdin.Fd()), oldState)
	}
}
