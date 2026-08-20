# mac-health Roadmap — from one rescued MacBook to a fleet

mac-health started as a live incident response: a 16" 2019 MacBook Pro
panicking with `userspace watchdog timeout: no successful checkins from
WindowServer`, traced to its AMD Radeon Pro 5300M throwing VMPT gpuRestart
storms until the compositor stalled. The tool now audits, monitors, and
auto-paces that machine. This roadmap turns it into a general rescue
daemon + CLI for the many dual-GPU Intel Macs with the same disease.

## 1. Generalize the core (v1.1)

**Delivered.**

- Machine-specific assumptions are gone. The console (GUI) user and home
  directory are resolved at runtime from `/dev/console` and `dscl`, so
  the LaunchAgent lands in the logged-in user's domain even under
  `sudo`; the agent's program path comes from the running binary rather
  than a hardcoded location.
- **Evidence-based fault detection** replaces the hardcoded "AMD is the
  faulting GPU" logic. `GPUInventory` reads the machine's actual GPU
  complement from `system_profiler SPDisplaysDataType` (`Bus: Built-In`
  is the integrated part, anything else discrete).
  `GPUIncidentParser` attributes each report strongest-evidence-first: a
  `Graphics Hardware:` header line, then a known device name appearing
  verbatim, then the driver-bundle family in a panic backtrace. Reports
  that name no hardware are counted as unattributed and never condemn a
  GPU by name. `GPUAuditor.muxVerdict` then flags only the mux mode that
  engages a part this machine's own reports have blamed, so dynamic
  switching stays green on a healthy machine and a faulting *integrated*
  GPU produces the opposite recommendation from a faulting dGPU.
- `--version` ships (`1.1.0`), and the `--json` payload carries
  `schemaVersion` (1) and `toolVersion`. The contract is written down
  field by field in [docs/json-schema.md](docs/json-schema.md), with the
  rule that additive fields do not bump the version and consumers refuse
  a payload from a higher one.
- Pulled forward from §5: meaningful exit codes (0 optimal, 1 degraded,
  2 critical; 64 usage error, 70 encode failure) are live.

**Still open in this line of work.**

- No semver git tags have been cut yet — the version lives only in
  `Core/Version.swift`.
- The LaunchAgent label is a fixed reverse-DNS string with a migration
  path off the old `com.robert.*` one, rather than being derived from a
  bundle identifier; a SwiftPM executable has no bundle to derive it
  from, so this needs a different source of truth (build setting or
  `Info.plist` embedded in the binary).
- A report the process cannot read is counted but unattributed. When the
  reports **directory** itself cannot be read — a standard account is not
  in the `_analyticsusers` group that owns it — the audit now reports
  `INCIDENT_SCAN_UNAVAILABLE` and refuses to call the machine healthy,
  rather than returning a silent all-clear.
- Per-user reports under `~/Library/Logs/DiagnosticReports` are still
  ignored; only the system-wide directory is scanned.

## 2. Split daemon / agent correctly (v1.2)

- **User LaunchAgent** (GUI session): the WindowServer IPC probe and
  user notifications — these need the Aqua session.
- **System LaunchDaemon** (root): actions that need privileges — `pmset`
  adjustments, pacing root-owned processes, and pre-emptive load
  shedding when thermal pressure turns serious.
- Communicate over XPC (or a shared state file as the minimal first
  step). The CLI talks to whichever half owns the request.

## 3. The rescue ladder (v1.2)

Escalating, always non-destructive, always logged:

1. **Observe** — audit continuously, keep 24h incident history.
2. **Pace** — `taskpolicy -b` + `renice` on batch workloads (AI agents,
   compilers, indexers) when WindowServer latency or thermal pressure
   rises. Never touch interactive apps; never kill anything.

   *Open question, and the most important one on this list:* does pacing
   actually reduce gpuRestart frequency? The storms observed so far fault
   on the VMPT (page-table) channel, and no evidence collected to date
   links them to CPU contention. Until a controlled comparison exists —
   restart rate under load with pacing on versus off — this rung stays
   explicitly experimental and must not be described as a fix. If the
   answer turns out to be no, the honest move is to delete this rung
   rather than keep shipping it.
3. **Warn** — user notification when a gpuRestart storm begins ("your
   GPU is faulting; save work"), carrying the part the reports named and
   the `gpuswitch` value that parks *that* part, well before the
   120-second watchdog deadline. The wording is already derived by
   `HealthAuditor.muxRecommendation`; what is missing is delivering it
   as a notification rather than a line in the audit output.
4. **Heal (opt-in)** — with user consent, apply the mux mode
   `muxVerdict` calls safe when the faulting-GPU signature is detected —
   `gpuswitch 0` for a faulting discrete GPU, `gpuswitch 1` for a
   faulting integrated one — and record the previous value so the action
   reverses with one command.

## 4. Distribution (v1.3)

- Signed + notarized artifacts: Developer ID-signed binary (hardened
  runtime, timestamped), notarized dmg/pkg, stapled tickets. The pkg
  installer registers the daemon+agent pair.
- **Homebrew tap** (`brew install ideasbyrobert/tap/mac-health`) for the
  CLI-first crowd.
- GitHub Actions release pipeline: build on macOS runners, codesign and
  notarize with repo secrets, staple, attach to GitHub Releases.

## 5. Fleet features (v2)

- MDM-friendly: config profile / plist-driven settings. The JSON audit
  output and the exit codes (0 healthy, 1 degraded, 2 critical) landed
  early, in v1.1; settings are still compiled-in constants.
- Opt-in anonymous incident telemetry (gpuRestart counts, watchdog
  saves) to learn which models and OS builds are suffering.
- ~~Incident playbooks in docs~~ — delivered:
  [docs/incident-playbooks.md](docs/incident-playbooks.md) covers
  "WindowServer watchdog panic", "gpuRestart storm", and "mux deadlock",
  each with the evidence to collect, the mitigation, and how to reverse
  it. They need revisiting whenever the rescue ladder above starts
  applying mitigations itself rather than recommending them.

## 6. Engineering hygiene

- Done: unit tests for every parser (pmset therm/custom/batt, vm_stat,
  `df`, `kmutil`, `system_profiler`, and the DiagnosticReports filename
  edge cases — spaces, hidden panic files) run off recorded fixtures
  through the `CommandRunning` / `FileReading` seams, plus end-to-end
  Intel-failure and Apple-Silicon workflow tests. CI
  (`.github/workflows/ci.yml`) builds, tests, and smoke-runs the binary
  on macOS 14 and macOS 15 runners.
- Still open: the sentinel's own overhead budget — < 0.5% CPU, zero
  allocations in the steady loop, no shell-outs on the hot path where a
  syscall or IOKit query will do. The loop currently shells out to
  `pgrep`, `ps`, and `pmset` every 5 seconds.
- Still open: a release workflow. CI proves the build; tagging, signing,
  notarizing, and attaching artifacts are all still manual (§4).

## Guiding principles

- **Evidence before action** — every mitigation traces to a diagnostic
  artifact the user can read.
- **Non-destructive always** — pace, never kill; recommend, never
  surprise.
- **The machine belongs to its user** — every automatic action is
  visible in the log and reversible with one command.
