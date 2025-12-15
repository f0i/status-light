#!/usr/bin/env bash
#
# Test script for sl.py LED wrapper
# This script outputs various patterns to trigger different LED states
#

echo "========================================="
echo "Starting Test Script"
echo "========================================="
echo ""

# Initial thinking state
echo "[INFO] Processing initial setup..."
sleep 1
echo "[INFO] Analyzing environment..."
sleep 1.5
echo "[SUCCESS] Setup complete"
echo ""

# Simulate a build process (thinking state)
echo "========================================="
echo "Stage 1: Building project"
echo "========================================="
echo "[BUILD] Compiling source files..."
sleep 0.8
echo "[BUILD] Processing dependencies..."
sleep 1.2
echo "[BUILD] Linking binaries..."
sleep 0.9
echo "[SUCCESS] Build complete"
echo ""

# Waiting state
echo "========================================="
echo "Stage 2: Interactive section"
echo "========================================="
echo "[WAIT] Waiting for resource allocation..."
sleep 2
echo "[WAIT] Checking availability..."
sleep 1.5
echo "[SUCCESS] Resources acquired"
echo ""

# More thinking
echo "========================================="
echo "Stage 3: Running tests"
echo "========================================="
echo "[TEST] Executing unit tests..."
sleep 1
echo "[TEST] Running integration tests..."
sleep 1.3
echo "[TEST] Performing validation checks..."
sleep 0.7
echo "[SUCCESS] All tests passed"
echo ""

# Another waiting state
echo "========================================="
echo "Stage 4: Deployment check"
echo "========================================="
echo "[DEPLOY] Waiting for confirmation..."
sleep 2.5
echo "[DEPLOY] Checking deployment status..."
sleep 1
echo "[SUCCESS] Ready to deploy"
echo ""

# Final processing
echo "========================================="
echo "Stage 5: Finalizing"
echo "========================================="
echo "[INFO] Processing final steps..."
sleep 0.8
echo "[INFO] Generating reports..."
sleep 1.1
echo "[INFO] Cleaning up temporary files..."
sleep 0.6
echo ""

# Completion
echo "========================================="
echo "Test Complete!"
echo "========================================="
echo "[SUCCESS] All stages completed successfully"
echo ""
echo "Summary:"
echo "  - Setup: OK"
echo "  - Build: OK"
echo "  - Tests: OK"
echo "  - Deploy: OK"
echo ""
echo "Exit code: 0"
