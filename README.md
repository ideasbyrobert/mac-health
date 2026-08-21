# mac-health

A native Swift CLI that reads a Mac's own diagnostic reports and tells you,
with evidence, which component they blame — then probes `WindowServer` latency,
audits GPU mux state, battery, thermals, kexts and disk, and emits the whole
verdict as JSON with meaningful exit codes.

Its primary job is **diagnosis**: turning "my Mac panicked and I don't know why"
into "twenty `.gpuRestart` reports name your AMD Radeon Pro 5300M on the VMPT
channel, and then the watchdog fired." An optional background sentinel is also
included; see the honest caveat on it below.

It also ships an **energy lab** — a CLI and a set of real worker processes —
for understanding where a machine's energy goes and why. Its
founding observation is that CPU percentage cannot tell a deadlocked process
from a healthy idle one; on this machine the two read 0.00% and 0.02%. Energy
signature can. See [docs/energy-lab.md](docs/energy-lab.md).

---

## Key Features

- **WindowServer & Watchdog Health Probe**: Proactively probes `WindowServer` Mach IPC round-trip latency via CoreGraphics to detect display compositor stalls long before the 120-second kernel watchdog triggers.
- **Evidence-Based GPU Fault Attribution**: Reads the machine's actual GPU complement from `system_profiler SPDisplaysDataType`, scans `/Library/Logs/DiagnosticReports/` for `.panic`, `.gpuRestart`, `.spin`, and `.shutdownStall` reports across a 24-hour window, and attributes each report to the GPU it names — the `Graphics Hardware:` header line first, then a known device name, then the driver bundle in a panic backtrace. Nothing is blamed without an artifact naming it; reports that name no hardware are counted separately as unattributed.
- **Hardware Mux Safety Verdict**: Inspects `gpuswitch` and judges the current mode against that evidence: a mode is unsafe only when it engages a GPU this machine's own reports have blamed. A healthy dual-GPU Mac stays green in every mode, and a machine whose *integrated* part is faulting is told to force the discrete GPU — the opposite of the AMD-specific advice this project started with.
- **Kernel & Extension Integrity**: Audits loaded kernel extensions (`kmutil`) for legacy, crash-prone third-party kexts (e.g. `DisableTurboBoost`).
- **Battery Health & Sleep Timers**: Evaluates battery condition degradation (`Service Recommended`) and validates display vs. system sleep timer coherency to prevent sleep-wake race conditions.
- **Universal Resource Governor**: Paces heavy background AI agents (`claude`, `agy`, `antigravity`, `node`), compilers (`swiftc`, `clang`, `xcodebuild`), and indexers (`mdworker`, `rg`) using non-destructive background QoS (`taskpolicy -b`, which includes throttled disk I/O) and `renice +15`. It never kills anything and never touches interactive apps.
- **Energy Lab**: Six real worker processes, each given the same nominal job and
  wrong in exactly one named way — a blocking wait, a polling loop, a spin, a
  lock-order inversion, a pipe-backpressure deadlock, and a memory-bound stall.
  The lab samples each one's kernel counters (`proc_pid_rusage`: cycles, retired
  instructions, interrupt and package-idle wakeups) plus a progress heartbeat,
  and names the pathology with an explicit confidence. It declines to name one
  when the counters genuinely cannot distinguish two explanations.
- **Wait-For Graph & Deadlock Detection**: A deadlock is a cycle in the graph of
  "who waits on whom". The lab builds that graph and searches it, which is the
  same algorithm a strategy planner uses to reject a circular dependency, run in
  the opposite direction. The run queue falls out of the same structure: it is
  the set of actors waiting on nothing.
- **Proactive Sentinel Daemon** (experimental, opt-in): A background service
  (`LaunchAgent`) that samples `WindowServer` latency and thermal pressure and
  paces batch workloads when either rises.

  > **What this does and does not claim.** Pacing background load measurably
  > reduces CPU contention, and that is all it is demonstrated to do. The idea
  > that it *prevents GPU restart storms or watchdog panics* is a hypothesis,
  > not a validated result: the gpuRestarts this project was built around fault
  > on the GPU's page-table (VMPT) channel, and nothing in the collected
  > evidence shows CPU contention triggers them. The mitigation that does
  > correlate with the storms stopping is the mux change (`pmset -a gpuswitch`),
  > which is a one-line command and needs no daemon. Run the sentinel if you
  > want the pacing and the logging; do not run it expecting a cure.

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

An audit reports its verdict through the process exit code, so a script can
branch on it without parsing anything:

| Code | Meaning |
| --- | --- |
| `0` | `OPTIMAL` |
| `1` | `DEGRADED_OR_WARNING` |
| `2` | `CRITICAL_ATTENTION_NEEDED` |
| `64` | Usage error |
| `70` | The report could not be encoded to JSON |

`--version`, `--help`, `pace`, and the `sentinel` subcommands exit `0`; the
`--watch` dashboard runs until interrupted and carries no verdict. The full
field-by-field contract for `--json` is in
[docs/json-schema.md](docs/json-schema.md).

### 2. Energy Lab

```bash
# Run every chaos scenario and show its energy signature
mac-health energy lab

# Run one scenario
mac-health energy lab deadlock

# List the scenarios and what each one teaches
mac-health energy scenarios

# Diagnose a live process from its kernel counters
mac-health energy watch <pid>
```

`energy lab` exits 0 when every scenario's pre-stated prediction held, 1 when
one did not — a prediction that cannot fail teaches nothing.

For a process the lab did not spawn there is no progress heartbeat, so `energy
watch` will say `indeterminate` rather than guess between a deadlock and a
healthy wait. That refusal is the point, not a limitation to work around.

### 3. Resource Governance
```bash
# One-shot scan and non-destructive pacing of background workloads
mac-health pace
```

### 4. Proactive Sentinel Service (Auto-Healing & Watchdog Guard)
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

### 5. Sleep Guard
```bash
# Keep the Mac fully awake: system and display never sleep
mac-health sleep never

# Keep the system awake while the display may still sleep
mac-health sleep dim

# Return to the Mac's own configured sleep behavior
mac-health sleep canonical

# Show the engaged mode, held assertions, and configured timers
mac-health sleep status
```

The guard holds IOKit power assertions from a LaunchAgent, so it survives
logout and reboot until told otherwise. It never edits `pmset`: the machine's
own timers remain the untouched canonical configuration, and `sleep canonical`
restores them by dropping the assertions rather than replaying saved values.
Closing the lid still sleeps the Mac; only `sudo pmset -a disablesleep 1`
changes that, and mac-health does not run sudo.

---

## Layout

The package splits into a library and a thin executable:

- **`MacHealthKit`** — every auditor, the governor, the sentinel policy, and
  the console renderer. The parsers take their input as strings and their
  system access through the `CommandRunning` and `FileReading` protocols, which
  is what lets the tests drive an entire Intel failure workflow off recorded
  fixtures.
- **`EnergyLab`** — the wait-for graph and its cycle detector, kernel-counter
  sampling, the pathology classifier with its confidence rules, the scenario
  catalogue, and the always-on process observer. It depends on `MacHealthKit`,
  never the reverse.
- **`chaos-worker`** — a small C executable that misbehaves on purpose, one
  named way per mode, publishing a progress heartbeat through shared memory so
  an observer can tell forward progress from its absence.
- **`MacHealthCLI`** — argument handling and exit codes, and nothing else.
  It produces the `mac-health` binary.
- **`Render`** — one presentation layer for the whole tool. `TerminalCapabilities`
  decides once whether the stream can carry colour, box drawing, and how wide it
  is, so no renderer has to think about escape codes.

---

## Building from Source

`make` is the supported path:

```bash
make build          # debug build
make release        # optimized build at .build/release/mac-health
make test           # run the test suite
make install        # install to $PREFIX/bin (PREFIX defaults to ~/.local)
make uninstall      # remove it again
make lab            # build, then run every chaos scenario
make notarized      # Developer ID-signed, notarized, stapled DMG in dist/
make clean
```

**Use `make test`, not `swift test`.** Swift Testing ships inside the Command
Line Tools at a path SwiftPM only discovers through an Xcode platform
directory, so on a machine with no full Xcode `swift test` fails with
`no such module 'Testing'`. The `test` target detects that case and hands
SwiftPM the framework and interop-dylib paths directly; with a full Xcode
installed it degrades to a plain `swift test`.

CI (`.github/workflows/ci.yml`) runs the release build, `make test`, and a
smoke pass of the shipped binary on macOS 14 and macOS 15 runners. The smoke
pass accepts exit codes `0`, `1`, and `2` from an audit, since those report the
runner's health rather than a build failure.

## Release: Signing & Notarization

```bash
# Sign the binary (hardened runtime, required for notarization)
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: <NAME> (<TEAMID>)" .build/release/mac-health

# Package and sign the dmg
hdiutil create -volname mac-health -srcfolder dist/mac-health -format UDZO mac-health-<ver>.dmg
codesign --force --timestamp --sign "Developer ID Application: <NAME> (<TEAMID>)" mac-health-<ver>.dmg

# Notarize (one-time: xcrun notarytool store-credentials <profile>)
xcrun notarytool submit mac-health-<ver>.dmg --keychain-profile <profile> --wait
xcrun stapler staple mac-health-<ver>.dmg
```

## Documentation

- [docs/json-schema.md](docs/json-schema.md) — the `--json` contract: every
  field, its units, the `schemaVersion` compatibility rule, the exit-code
  table, and a worked example payload.
- [docs/incident-playbooks.md](docs/incident-playbooks.md) — "WindowServer
  watchdog panic", "gpuRestart storm", and "mux deadlock": the evidence to
  collect, what mac-health reports, the mitigation and why, and how to
  reverse it.
- [docs/energy-lab.md](docs/energy-lab.md) — the lab: why CPU percentage cannot
  separate a deadlock from an idle wait, the measured signature of each
  pathology, the classifier's decision tree, and what confidence each verdict
  earns.
- [docs/os-as-distributed-system.md](docs/os-as-distributed-system.md) — the
  conceptual piece: a process as a service, a mutex as a distributed lock, a
  pipe as a bounded queue with backpressure — and, given equal weight, where
  that analogy breaks.
- [ROADMAP.md](ROADMAP.md) — the plan to grow this into a general rescue
  daemon + CLI for dual-GPU Intel Macs.
