# mac-health Roadmap — from one rescued MacBook to a fleet

mac-health started as a live incident response: a 16" 2019 MacBook Pro
panicking with `userspace watchdog timeout: no successful checkins from
WindowServer`, traced to its AMD Radeon Pro 5300M throwing VMPT gpuRestart
storms until the compositor stalled. The tool now audits, monitors, and
auto-paces that machine. This roadmap turns it into a general rescue
daemon + CLI for the many dual-GPU Intel Macs with the same disease.

## 1. Generalize the core (v1.1)

- Remove every machine-specific assumption: hardcoded `/Users/robert`
  paths, the `robert` uid/label, the AMD-specific audit strings.
  Resolve the console user and home directory at runtime; derive the
  LaunchAgent label from the bundle identifier.
- Replace the hardcoded "AMD is the faulting GPU" logic with **evidence-
  based fault detection**: parse `/Library/Logs/DiagnosticReports` at
  runtime, attribute gpuRestart/spin/panic reports to a GPU (the reports
  name the hardware), and only then flag the mux mode that engages the
  faulting device. On healthy machines, dynamic switching stays green.
- Add `--version` and semver tags; stable JSON schema (`mac-health
  --json`) as the machine-readable contract for scripts and MDM.

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
3. **Warn** — user notification when a gpuRestart storm begins
   ("your GPU is faulting; save work; consider gpuswitch 0"), well
   before the 120-second watchdog deadline.
4. **Heal (opt-in)** — with user consent, apply the safe mux mode
   automatically when the faulting-GPU signature is detected.

## 4. Distribution (v1.3)

- Signed + notarized artifacts: Developer ID-signed binary (hardened
  runtime, timestamped), notarized dmg/pkg, stapled tickets. The pkg
  installer registers the daemon+agent pair.
- **Homebrew tap** (`brew install ideasbyrobert/tap/mac-health`) for the
  CLI-first crowd.
- GitHub Actions release pipeline: build on macOS runners, codesign and
  notarize with repo secrets, staple, attach to GitHub Releases.

## 5. Fleet features (v2)

- MDM-friendly: config profile / plist-driven settings, JSON audit
  output, meaningful exit codes (0 healthy, 1 degraded, 2 critical).
- Opt-in anonymous incident telemetry (gpuRestart counts, watchdog
  saves) to learn which models and OS builds are suffering.
- Incident playbooks in docs: "WindowServer watchdog panic",
  "gpuRestart storm", "mux deadlock" — each with the evidence to
  collect and the mitigation the tool applies.

## 6. Engineering hygiene

- Unit tests for every parser (pmset, vm_stat, therm, DiagnosticReports
  filename edge cases — spaces, hidden `.contents.panic` files) with
  recorded fixtures; CI on macOS runners.
- The sentinel's own overhead budget: < 0.5% CPU, zero allocations in
  the steady loop, no shell-outs on the hot path where a syscall or
  IOKit query will do.

## Guiding principles

- **Evidence before action** — every mitigation traces to a diagnostic
  artifact the user can read.
- **Non-destructive always** — pace, never kill; recommend, never
  surprise.
- **The machine belongs to its user** — every automatic action is
  visible in the log and reversible with one command.
