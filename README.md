# mac-health

A high-performance, native Swift CLI utility and proactive background sentinel to audit macOS hardware health, probe `WindowServer` latency, prevent GPU switching deadlocks and userspace watchdog panics, govern resource hogs, and ensure compilation readiness.

---

## Key Features

- **WindowServer & Watchdog Health Probe**: Proactively probes `WindowServer` Mach IPC round-trip latency via CoreGraphics to detect display compositor stalls long before the 120-second kernel watchdog triggers.
- **GPU Stability & Hardware Mux Audit**: Inspects discrete vs. dynamic GPU multiplexing (`gpuswitch`) and scans `/Library/Logs/DiagnosticReports/` for panics, `.gpuRestart`, `.spin`, and shutdown stalls across 24-hour windows.
- **Kernel & Extension Integrity**: Audits loaded kernel extensions (`kmutil`) for legacy, crash-prone third-party kexts (e.g. `DisableTurboBoost`).
- **Battery Health & Sleep Timers**: Evaluates battery condition degradation (`Service Recommended`) and validates display vs. system sleep timer coherency to prevent sleep-wake race conditions.
- **Universal Resource Governor**: Automatically paces heavy background AI agents (`claude`, `agy`, `antigravity`, `node`), compilers (`swiftc`, `clang`, `xcodebuild`), and indexers (`mdworker`, `rg`) using non-destructive background QoS (`taskpolicy -b -d`) and `renice +15`.
- **Proactive Sentinel Daemon**: A lightweight background sentinel service (PID managed via `LaunchAgent`) that continuously monitors `WindowServer` latency and thermal throttling, automatically shedding system contention to keep interactive UI responsive and prevent panics.

---

## Usage

### 1. Diagnostic Audit
```bash
# Run standard health and watchdog audit
mac-health

# Output machine-readable JSON (for scripts or AI agents)
mac-health --json

# Continuous live terminal dashboard (refreshes every 2s)
mac-health --watch 2
```

### 2. Resource Governance
```bash
# One-shot scan and non-destructive pacing of background workloads
mac-health pace
```

### 3. Proactive Sentinel Service (Auto-Healing & Watchdog Guard)
```bash
# Run proactive sentinel in foreground
mac-health sentinel

# Install continuous background LaunchAgent across reboots
mac-health sentinel install

# Check sentinel background service status
mac-health sentinel status

# Uninstall background LaunchAgent
mac-health sentinel uninstall
```

---

## Building from Source

```bash
swiftc -O -framework CoreGraphics Sources/MacHealth/main.swift -o mac-health
cp mac-health ~/.local/bin/mac-health
```
