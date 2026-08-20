# Incident playbooks

Three failure modes, each with the evidence to collect, what `mac-health`
reports for it, the mitigation it recommends and why, and how to undo that
mitigation.

Two ground rules run through all of them:

- **Evidence before action.** Every mitigation below traces to a diagnostic
  artifact you can open and read yourself. If the evidence is not there, the
  tool does not name a culprit — it counts the incident as unattributed and
  says so.
- **Nothing here is destructive.** No mitigation kills a process or edits a
  system file, and every one of them reverses with a single command.

Where a claim about macOS's own behaviour is uncertain, it is marked as such
rather than asserted.

---

## 1. WindowServer watchdog panic

### Symptom

The machine freezes — cursor stops, audio loops or cuts — and reboots on its
own after roughly two minutes. On the way back up macOS shows the "Your
computer restarted because of a problem" dialog. The freeze duration matters:
the kernel's userspace watchdog panics deliberately when WindowServer stops
checking in for 120 seconds, so a hang shorter than that is a stall, and a hang
that ends in a reboot is this.

### Evidence to collect

```bash
ls -lt /Library/Logs/DiagnosticReports/*.panic
```

Panic reports are JSON. The field that identifies this failure is
`panic_string`:

```bash
grep -o '"panic_string":"[^"]*"' /Library/Logs/DiagnosticReports/*.panic
```

The signature to look for:

```
panic(cpu 4 caller 0x...): userspace watchdog timeout: no successful checkins
from WindowServer (2 induced crashes) in 120 seconds
```

The parenthesised "induced crashes" count is how many times the watchdog had
already tried to restart the compositor before it gave up and panicked.

Depending on the macOS version the file may carry a leading metadata line
before the object that holds `panic_string`, so feed lines to `jq` one at a
time rather than assuming the whole file parses as a single document.

A companion `.spin` report is often written just before the panic, named like
`WindowServer_2026-08-19-223045_hostname.userspace_watchdog_timeout.spin`. It
contains the sampled backtraces of the stalled compositor, and it is where a
driver-bundle name (`AMDRadeonX6000…`, `AppleIntel…`) usually shows up when the
panic itself names no hardware.

### What mac-health reports

- The `.panic` and `.spin` files are counted in `gpu.historicalIncidents24h`,
  and in `gpu.activeIncidentsLastHour` if they are less than an hour old — the
  latter makes the run **critical**, exit code `2`.
- If a driver bundle appears in the report header, the incident is attributed
  to that vendor's GPU in `gpu.incidentsByGPU`. Panic JSON frequently names no
  graphics hardware at all, in which case it lands in
  `gpu.unattributedIncidents` and blames nobody.
- Live, before a panic: `windowServer.latencyMs` is the CoreGraphics IPC
  round-trip. `status` goes to `ELEVATED_LATENCY` above 200 ms and
  `UNRESPONSIVE_STALL_DETECTED` at 1000 ms or on probe timeout. The sentinel
  reacts at 250 ms.

### Mitigation and why

`mac-health sentinel` samples that latency every 5 seconds and, on a spike or
on thermal pressure, runs the governor: `taskpolicy -b` (background QoS, which
includes throttled disk I/O) plus `renice +15` on AI agents, compilers, and
indexers. Nothing is killed and no interactive app is touched.

The reasoning is that the watchdog fires on a *deadline*, not on a resource
threshold. WindowServer only needs enough CPU and I/O to check in; the failure
mode is a machine so contended that the compositor cannot get scheduled inside
120 seconds. Shedding batch load restores the headroom that keeps it under the
deadline. This does not fix a compositor stalled inside a faulting GPU driver —
for that, see playbook 2.

One-shot, without the daemon:

```bash
mac-health pace
```

### Reversing it

- Stop the background service: `mac-health sentinel uninstall` (removes the
  LaunchAgent and stops the running daemon).
- The pacing itself is per-process and not persistent: `taskpolicy -b` and
  `renice` apply to the PIDs that were running at the time and die with them.
  Quitting and relaunching the affected process restores its default QoS and
  priority. Note that a non-root user cannot lower a nice value back down, so
  restarting the process is the reliable way to undo `renice +15`.

---

## 2. gpuRestart storm

### Symptom

Brief full-screen flickers or black frames, a second or two of frozen UI, and
sometimes a "graphics device restarted" notice. Individually survivable; the
problem is the storm. Repeated resets stall the compositor, and enough of them
in a row turn into playbook 1.

### Evidence to collect

```bash
ls -lt /Library/Logs/DiagnosticReports/*.gpuRestart
```

These reports are plain text and name the faulting part in their header:

```
Event:               GPU Reset
Date/Time:           Wed Aug 19 22:31:30 2026
Tailspin:            /Library/Logs/DiagnosticReports/gpuRestart2026-08-19-223130.tailspin
OS Version:          Mac OS X Version 26.6.2 (Build 25G83)
Graphics Hardware:   AMD Radeon Pro 5300M
Signature:           2

Report Data:

GPU Log Version: 2

Restart Channel: 18 VMPT

---THE STATE OF THE DRIVER---

AMDRadeonX6000_AMDNavi14GraphicsAccelerator state: ENABLED
 PCIe Device: [3:0:0], DID=0x7340, RID=0x43, SSID=0x210
```

The three lines that matter:

- **`Graphics Hardware:`** — the authoritative attribution. This is the exact
  device name, and it matches the `Chipset Model:` that
  `system_profiler SPDisplaysDataType` prints for the same part.
- **`Restart Channel:`** — the hardware channel that hung, here `VMPT`. Its
  precise meaning is internal to the vendor driver and not publicly
  documented; treat it as a fingerprint that lets you tell one recurring
  failure apart from another, not as a diagnosis.
- **The accelerator bundle name** in the driver state dump
  (`AMDRadeonX6000_AMDNavi14GraphicsAccelerator`) — the fallback used when a
  report carries no `Graphics Hardware:` line.

Count them and group by hardware:

```bash
grep -h "^Graphics Hardware:" /Library/Logs/DiagnosticReports/*.gpuRestart | sort | uniq -c
grep -h "^Restart Channel:"   /Library/Logs/DiagnosticReports/*.gpuRestart | sort | uniq -c
```

Confirm what is actually installed:

```bash
system_profiler SPDisplaysDataType | grep -E "Chipset Model:|Bus:"
```

`Bus: Built-In` is the integrated GPU; `Bus: PCIe` (or Thunderbolt, for an
eGPU) is discrete. That distinction is what decides which mitigation applies.

### What mac-health reports

- Each report is one incident; `gpu.incidentsByGPU` is keyed by the attributed
  device, `gpu.faultingGPU` is the one with the most, and
  `gpu.faultingGPUIsDiscrete` says which side of the mux it sits on.
- `gpu.restartChannels` carries the distinct channel names, e.g. `["VMPT"]`.
- Reports that are unreadable, or that name no hardware, increment
  `gpu.unattributedIncidents` — they are counted but they never condemn a GPU
  by name.
- `gpu.status` is `HISTORICAL_PANICS_RECORDED` for a 24-hour history and
  `ACTIVE_HANGS_LAST_HOUR` if any incident is under an hour old.

A live example from the machine this tool was written on: 21 reports naming
`AMD Radeon Pro 5300M` on the VMPT channel, 3 unattributed, 24 in the 24-hour
window.

### Mitigation and why

Park the faulting part. On a dual-GPU Intel MacBook Pro the mux is controlled
by `pmset`:

```bash
sudo pmset -a gpuswitch 0   # integrated only — parks the discrete GPU
sudo pmset -a gpuswitch 1   # discrete only  — parks the integrated GPU
```

`mac-health` recommends whichever of those keeps `faultingGPU` idle, and says
so in `xcodeReadiness.recommendations` with the report count and channel as
justification. On the machine above that is `gpuswitch 0`.

The caveat the tool prints with it, because it is the usual reason the
mitigation appears not to work: **on many dual-GPU MacBook Pros the external
display outputs are wired to the discrete GPU**, so attaching a monitor
re-engages the part you just parked. Verify with a `.gpuRestart` count after a
day of the intended usage, not with the setting alone.

Pacing (playbook 1) is complementary, not a substitute: it buys the compositor
scheduling headroom, but it cannot stop a GPU that is resetting in its own
driver.

### Reversing it

```bash
sudo pmset -a gpuswitch 2   # restore dynamic switching
pmset -g custom | grep gpuswitch
```

`mac-health` never changes `gpuswitch` itself; it only recommends. Whether a
change takes effect immediately, at next login, or at next boot has varied
across macOS versions — if the mode you set is not reflected in behaviour,
log out and back in, or reboot, and re-check `pmset -g custom`.

---

## 3. Mux deadlock

### Symptom

The display goes black or the UI freezes at the moment something triggers a GPU
switch: plugging in an external monitor, launching an app that requests the
discrete GPU, waking from sleep, or unplugging power. Unlike a gpuRestart
storm, this is not a stream of resets — it is one transition that never
completes. The machine may recover after a long pause, or it may sit there
until the watchdog in playbook 1 fires.

### Evidence to collect

First, is there a mux at all? Apple Silicon and single-GPU Intel Macs have no
`gpuswitch` key, and this playbook does not apply to them:

```bash
pmset -g custom | grep gpuswitch
system_profiler SPDisplaysDataType | grep -E "Chipset Model:|Bus:"
```

Two GPUs and a `gpuswitch` line means the mux is live. Then correlate the hang
with a switch:

```bash
ls -lt /Library/Logs/DiagnosticReports/ | head -20
log show --last 1h --predicate 'process == "WindowServer"' --info 2>/dev/null | tail -100
```

The artifacts to expect, in descending order of how conclusive they are:

- a `.gpuRestart` whose `Graphics Hardware:` names the part being switched to,
  timestamped at the transition;
- a `.spin` for `WindowServer` at the same moment, whose backtrace names a
  framebuffer or accelerator bundle (`AMDFramebuffer`, `AppleIntelFramebuffer`,
  `AMDRadeonX…`);
- a `.panic` with the userspace watchdog string, if the transition never
  completed;
- a `.shutdownStall`, if the machine hung while shutting down rather than
  while running.

`mac-health` reads all four kinds. Note that a report it cannot open — a
permissions failure on a panic log, most often — is still counted, but as
unattributed.

Honest limitation: macOS does not emit an artifact that says "the mux switch
deadlocked". The diagnosis is circumstantial — a hang whose timestamp coincides
with a switching event on a machine that has a mux. Do not treat the mode as
proven guilty on a single hang.

### What mac-health reports

- `gpu.gpuSwitchMode` is the current mode, and `gpu.gpuSwitchSafe` is the
  verdict: *does this mode engage a GPU that this machine's own reports have
  blamed in the last 24 hours?* Dynamic switching engages both parts, so either
  one faulting makes it unsafe; integrated-only is unsafe only if the
  **integrated** GPU is faulting; discrete-only only if the discrete one is.
- An unsafe mode degrades `overallHealth` and withdraws
  `xcodeReadiness.gpuStable`. Note that `gpu.status` will almost always read
  `HISTORICAL_PANICS_RECORDED` rather than `DYNAMIC_SWITCHING_UNSAFE`: an
  unsafe mux requires incidents, and the incident branch is evaluated first.
  Read `gpuSwitchSafe`, not `status`, to test the mux verdict.
- When a GPU-shaped report (`.gpuRestart` or `.panic`) names no hardware, the
  tool falls back to suspecting the discrete GPU. A `.spin` or `.shutdownStall`
  never triggers that fallback. This is a conservative bias, stated here so it
  is not mistaken for evidence: `gpu.unattributedIncidents > 0` with an empty
  `gpu.incidentsByGPU` means the recommendation rests on a prior, not on a
  report that named the part.
- A healthy dual-GPU machine stays green in every mode. Dynamic switching is
  not treated as a defect on its own.

### Mitigation and why

Pin the mux so no transition happens, choosing the mode that keeps the faulting
part idle — `sudo pmset -a gpuswitch 0` for a faulting dGPU, `gpuswitch 1` for a
faulting iGPU. A pinned mux removes the transition that deadlocks, which is a
stronger guarantee than avoiding the faulting GPU: even a healthy pair cannot
deadlock a switch it never performs.

The costs are real and worth stating before you apply it. `gpuswitch 1` runs
the discrete GPU continuously and measurably shortens battery life and raises
temperatures. `gpuswitch 0` gives up discrete-GPU performance, and on many
models it does not survive attaching an external display, whose outputs are
wired to the dGPU.

### Reversing it

```bash
sudo pmset -a gpuswitch 2   # dynamic switching, the macOS default
pmset -g custom | grep gpuswitch
```

If dynamic switching was pinned because of a fault that has since been
repaired — a logic board replacement, an OS update that shipped a new driver —
clear the history that justified it by confirming a full 24 hours with no new
reports:

```bash
find /Library/Logs/DiagnosticReports -type f \
  \( -name "*.gpuRestart" -o -name "*.spin" -o -name "*.panic" -o -name "*.shutdownStall" \) \
  -mtime -1
mac-health --json | jq '.gpu'
```

An empty find and a `gpu.historicalIncidents24h` of `0` is the tool agreeing
that there is no longer evidence against any mode.
