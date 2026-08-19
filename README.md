# mac-health

A native, zero-dependency Swift CLI utility to audit macOS hardware health, thermal throttling, GPU stability, memory swap pressure, guardrail daemons, and Xcode/compilation readiness.

---

## Features

- **CPU & Thermal Throttling Audit**: Parses `pmset -g therm` for speed limits, scheduler limits, and thermal degradation warnings.
- **Memory & Swap Pressure**: Reads Mach virtual memory stats and system swap usage without thrashing.
- **GPU Crash & Hang Monitor**: Scans `/Library/Logs/DiagnosticReports/` for `.gpuRestart`, watchdog `.spin` timeouts, and kernel panics.
- **Guardrail Daemon Tracking**: Verifies that `gSwitch` (GPU isolator) and `Turbo Boost Switcher Pro` (thermal regulator) are active.
- **Power & Sleep Assertions**: Confirms safe sleep delays, AC power status, and active `caffeinate` locks.
- **Xcode & Heavy Workload Readiness**: Assesses available disk space (requiring >= 45 GB) and thermal headroom for Xcode installations and large compiles.
- **Machine & Human Interfaces**: Supports colored terminal output, live polling (`--watch <sec>`), and structured JSON (`--json`).

---

## Usage

```bash
# Run standard health audit
mac-health

# Continuous live monitoring (poll every 2 seconds)
mac-health --watch 2

# Emit machine-readable JSON for AI agents or scripts
mac-health --json
```

---

## Building from Source

```bash
swiftc -O Sources/MacHealth/main.swift -o mac-health
cp mac-health ~/.local/bin/mac-health
```
