# `mac-health --json` — machine-readable contract

`mac-health --json` prints one `DiagnosticReport` object to stdout and exits
with the health verdict (see [Exit codes](#exit-codes)). Errors go to stderr,
never to stdout, so stdout is always either a complete JSON document or empty.

The encoder is configured with pretty-printing, sorted keys, and ISO 8601
dates, so the output is stable enough to diff between runs. JSON keys are the
Swift property names verbatim; there are no custom coding keys and no key
transformation.

## Versioning

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Version of this contract. Currently **1**. |
| `toolVersion` | Semantic version of the binary that produced the payload (currently `1.1.0`). |

The compatibility rule:

- **Adding a field does not bump `schemaVersion`.** A consumer must ignore
  keys it does not recognise.
- `schemaVersion` is bumped only on a breaking change — a field removed, a
  field renamed, or the meaning or units of an existing field changed.
- A consumer should **refuse a payload whose `schemaVersion` is higher than the
  version it was written against**, because a higher version means a field it
  relies on may no longer mean what it did.
- `toolVersion` moves independently and carries no compatibility promise; use
  it for reporting and telemetry, not for gating.

## Top level — `DiagnosticReport`

| Field | Type | Meaning |
| --- | --- | --- |
| `schemaVersion` | integer | Contract version, see above. |
| `toolVersion` | string | Binary version, e.g. `"1.1.0"`. |
| `timestamp` | string | Time the audit ran, ISO 8601 (`2026-08-20T05:43:02Z`). |
| `overallHealth` | string | `OPTIMAL`, `DEGRADED_OR_WARNING`, or `CRITICAL_ATTENTION_NEEDED`. Maps one-to-one onto the exit code. |
| `cpu` | object | [`CPUMetrics`](#cpu). |
| `memory` | object | [`MemoryMetrics`](#memory). |
| `gpu` | object | [`GPUMetrics`](#gpu). |
| `windowServer` | object | [`WindowServerMetrics`](#windowserver). |
| `power` | object | [`PowerMetrics`](#power). |
| `disk` | object | [`DiskMetrics`](#disk). |
| `kernelExtensions` | object | [`KernelExtensionsMetrics`](#kernelextensions). |
| `xcodeReadiness` | object | [`XcodeReadiness`](#xcodereadiness). |

### How `overallHealth` is derived

The verdict is **critical** if either of these holds:

- `gpu.activeIncidentsLastHour > 0`
- `windowServer.isResponsive == false` or `windowServer.latencyMs > 500`

Otherwise it is **degraded** if any of these holds:

- `cpu.speedLimitPercent < 100` or `cpu.thermalWarning`
- `memory.pagesThrottled > 0`
- `gpu.historicalIncidents24h > 0` and `gpu.hoursSinceLastCrash < 24`
- `gpu.gpuSwitchSafe == false`
- `power.isBatteryDegraded`
- `power.sleepTimingsCoherent == false`
- `kernelExtensions.isCleanNative == false`

Otherwise it is **optimal**. Note that the two critical conditions also set
the degraded conditions; critical always wins.

## cpu

`CPUMetrics`. Sourced from `sysctl` and `pmset -g therm`.

| Field | Type | Meaning |
| --- | --- | --- |
| `model` | string | `machdep.cpu.brand_string`. |
| `physicalCores` | integer | `hw.physicalcpu`. `0` if the sysctl could not be read. |
| `logicalCores` | integer | `hw.logicalcpu`. `0` if the sysctl could not be read. |
| `speedLimitPercent` | integer | `CPU_Speed_Limit` from `pmset -g therm`, percent of nominal clock. **Defaults to `100` when the key is absent**, which is the normal case on many Apple Silicon states. |
| `schedulerLimitPercent` | integer | `CPU_Scheduler_Limit`, percent. Same default of `100`. |
| `thermalWarning` | boolean | A thermal warning line was present in `pmset -g therm` (a line saying "no thermal warning" does not set it). |
| `status` | string | `HEALTHY` when `speedLimitPercent == 100` and no thermal warning, otherwise `THROTTLED`. |

## memory

`MemoryMetrics`. Sourced from `sysctl hw.memsize`, `sysctl vm.swapusage`, and
`vm_stat`.

| Field | Type | Meaning |
| --- | --- | --- |
| `totalPhysicalGB` | number | Installed RAM in GiB (`hw.memsize / 1024³`). |
| `freeGB` | number | `Pages free` from `vm_stat` × 4096 bytes, in GiB. This is *free* memory, not macOS's "available" memory, so a healthy machine can legitimately report a small number here. |
| `swapUsedMB` | number | `used` from `vm.swapusage`, in the megabytes that sysctl prints. |
| `swapFreeMB` | number | `free` from `vm.swapusage`, in megabytes. |
| `pagesThrottled` | integer | `Pages throttled` from `vm_stat`. Any non-zero value means the VM subsystem is thrashing and degrades the verdict. |
| `status` | string | `OPTIMAL` when `pagesThrottled == 0`, otherwise `PRESSURE`. |

## gpu

`GPUMetrics`. This is the subsystem the tool exists for, and the one where the
evidence rules matter.

| Field | Type | Meaning |
| --- | --- | --- |
| `activeIncidentsLastHour` | integer | Diagnostic reports younger than 1 hour. Non-zero makes the run **critical**. |
| `historicalIncidents24h` | integer | Diagnostic reports in the last 24 hours. Equals `sum(incidentsByGPU) + unattributedIncidents`. |
| `hoursSinceLastCrash` | number | Age in hours of the newest report. **`999.0` is the sentinel for "no incidents at all"** — do not read it as an elapsed time. |
| `gpuSwitchMode` | string | Human-readable mux mode, see [Mux modes](#mux-modes). |
| `gpuSwitchSafe` | boolean | Whether the current mux mode keeps the faulting GPU idle, see [Mux safety](#mux-safety). |
| `status` | string | `INCIDENT_SCAN_UNAVAILABLE`, `ACTIVE_HANGS_LAST_HOUR`, `HISTORICAL_PANICS_RECORDED`, `DYNAMIC_SWITCHING_UNSAFE`, or `STABLE`, evaluated in that order. `DYNAMIC_SWITCHING_UNSAFE` is rare in practice — an unsafe mux requires incidents, and the incident branches are evaluated first — so test `gpuSwitchSafe` rather than this string. |
| `latestIncidentName` | string, key absent when nil | Filename of the newest report, e.g. `gpuRestart2026-08-19-223130.gpuRestart`. The key is omitted entirely when there are none. |
| `latestIncidentTime` | string, key absent when nil | Newest report's time formatted for display in the local timezone (`h:mm a`), with no date. **Display only** — use `hoursSinceLastCrash` for arithmetic. |
| `installedGPUs` | array of object | Every GPU `system_profiler SPDisplaysDataType` reports. Each entry is `{ "name": string, "isDiscrete": boolean }`. `isDiscrete` is false only for a GPU whose `Bus:` is `Built-In`; PCIe and Thunderbolt (eGPU) parts are discrete. |
| `incidentsByGPU` | object | Map of GPU name → count of reports attributed to it. Keys are canonicalised onto `installedGPUs[].name` where possible. Empty when nothing could be attributed. |
| `unattributedIncidents` | integer | Reports that named no hardware, or that could not be read. |
| `faultingGPU` | string, key absent when nil | The GPU with the most attributed incidents; ties break alphabetically so the verdict is stable across runs. The key is omitted entirely when `incidentsByGPU` is empty. |
| `faultingGPUIsDiscrete` | boolean | Whether `faultingGPU` matches an entry of `installedGPUs` marked discrete. **False when `faultingGPU` is null** — check `faultingGPU` first rather than trusting this flag alone. |
| `restartChannels` | array of string | Distinct `Restart Channel:` values seen in `.gpuRestart` reports, e.g. `["VMPT"]`, in first-seen (newest-first) order. |
| `incidentScanAvailable` | boolean | **Check this before trusting any count above.** False when `/Library/Logs/DiagnosticReports` could not be read at all, in which case every incident count is `0` because nothing was scanned — not because the machine is healthy. See "Reading the incident scan" below. |

### Which reports are counted

The auditor collects, newest first:

```
find /Library/Logs/DiagnosticReports/ -type f \
  \( -name "*.gpuRestart" -o -name "*.spin" -o -name "*.panic" -o -name "*.shutdownStall" \) \
  -mtime -1
```

Age comes from the file's mtime. Filenames may contain spaces and may be
hidden (a leading dot), and both cases are handled.

### Attribution rules

For each report, the first 16 KiB of the file is read and evidence is applied
strongest-first:

1. **An explicit header line.** `Graphics Hardware:   AMD Radeon Pro 5300M` in
   a `.gpuRestart` report names the part outright. The value is canonicalised
   against `installedGPUs`; if it matches nothing on this machine, the raw
   string is used as the key.
2. **A known device name appearing verbatim** anywhere in the header, matched
   case-insensitively against `installedGPUs[].name`.
3. **A driver-bundle family** in a panic backtrace or driver state dump:
   `AMDRadeonX*` / `AMDNavi*` / `AMDFramebuffer` / `ATIRadeon` / `AMDMTLBronze`
   → AMD, `AppleIntel*` / `IntelAccelerator` / `IntelFramebuffer` → Intel,
   `AGXAccelerator` / `AGXG*` / `AppleParavirtGPU` → Apple,
   `NVDAResman` / `nvAccelerator` / `GeForce` → NVIDIA. The vendor is then
   resolved to one of this machine's own GPUs.

If none of those match — or the file could not be read, which is the usual
reason a panic log contributes nothing — the report increments
`unattributedIncidents` and **no GPU is blamed for it**. An unattributed
incident never puts a name in `incidentsByGPU`.

### Mux modes

`gpuSwitchMode` is derived from the `gpuswitch` value in `pmset -g custom`:

| `gpuswitch` | Meaning | `gpuSwitchMode` |
| --- | --- | --- |
| absent | No switchable mux — Apple Silicon or a single-GPU Intel Mac | `No switchable mux (Apple Silicon / single-GPU)` |
| `0` | Integrated only, discrete GPU parked | `Integrated Only (discrete GPU kept idle)` or `Integrated Only (Faulting iGPU Engaged!)` |
| `1` | Discrete only | `Discrete Only (dGPU forced)` or `Discrete Only (Faulting dGPU Engaged!)` |
| `2` (and any other value) | Dynamic switching, both parts in play | `Dynamic Switching` or `Dynamic Switching (Faulting GPU Engaged!)` |

### Mux safety

`gpuSwitchSafe` answers one question: *does the current mode engage a GPU that
this machine's own reports have blamed in the last 24 hours?*

- No mux → always safe.
- Integrated only → unsafe **only** if the integrated GPU is faulting.
- Discrete only → unsafe if the discrete GPU is faulting.
- Dynamic → unsafe if either part is faulting.

When a report is **GPU-shaped but names no hardware** — a `.gpuRestart`, which
is by definition a GPU reset, or a `.panic` — the tool falls back to suspecting
the **discrete** GPU. That is a deliberate conservative bias: it applies to
modes `1` and dynamic, never makes integrated-only unsafe, and requires the
machine to actually have a discrete GPU.

### Reading the incident scan

`/Library/Logs/DiagnosticReports` is mode `0770`, owned by `root:_analyticsusers`.
An administrator account is a member of that group; a **standard account is
not**. When the directory cannot be read, the tool cannot distinguish "no
crashes" from "not allowed to look", so it says so explicitly rather than
guessing:

- `gpu.incidentScanAvailable` is `false`
- `gpu.status` is `INCIDENT_SCAN_UNAVAILABLE`
- `overallHealth` is never `OPTIMAL` (so the exit code is never `0`)
- `xcodeReadiness.gpuStable` is `false` and a recommendation explains the cause
- **no GPU is accused** — absence of evidence is not evidence of a fault, so
  `gpuSwitchSafe` stays `true` in every mode

Any consumer that reads `historicalIncidents24h` must gate on
`incidentScanAvailable` first. A fleet check that skips it will read an
unprivileged run as a clean machine.

### The mux fallback

The fallback is deliberately **not** triggered by `.spin` or `.shutdownStall`
reports. Those are stalls — a symptom with many causes — so counting one as GPU
blame would let a single unrelated shutdown hang recommend a mux change. They
still appear in `historicalIncidents24h` and `unattributedIncidents`; they just
do not convict a GPU.

Note that the bias is keyed on *unattributed GPU-shaped evidence*, not on the
presence of any unattributed report: a run with 21 reports attributed to the
dGPU and 3 unreadable `.spin` files draws its verdict from the 21.

The consequence worth stating plainly: a healthy dual-GPU Mac stays green in
every mux mode, and a machine whose *integrated* part is faulting is told to
force the discrete GPU rather than being handed the AMD-specific advice this
project started with.

## windowServer

`WindowServerMetrics`. The latency figure is a CoreGraphics
`CGWindowListCopyWindowInfo` round trip, which is a Mach IPC call into
WindowServer, run on a background queue behind a hard 1500 ms timeout.

| Field | Type | Meaning |
| --- | --- | --- |
| `latencyMs` | number | Probe round-trip time in milliseconds. **When the probe times out this is exactly `1500.0`**, the timeout constant, not a measurement. |
| `isResponsive` | boolean | False when the probe timed out. Read this before trusting `latencyMs`. |
| `cpuPercent` | number | `ps -o %cpu` for the WindowServer process; `0` when the process could not be found. |
| `sleepAssertionHolder` | boolean | WindowServer appears in `pmset -g assertions`. |
| `status` | string | `UNRESPONSIVE_STALL_DETECTED` (not responsive or ≥ 1000 ms), `ELEVATED_LATENCY` (> 200 ms or CPU > 80%), otherwise `RESPONSIVE`. |

## power

`PowerMetrics`. Sourced from `pmset -g batt`, `pmset -g custom`,
`pmset -g assertions`, and `system_profiler SPPowerDataType`.

| Field | Type | Meaning |
| --- | --- | --- |
| `powerSource` | string | `AC Charger` or `Battery`. |
| `batteryPercentage` | integer | Charge percent; defaults to `100` when no percentage could be parsed (desktops). |
| `batteryCondition` | string | Apple's condition string, e.g. `Normal` or `Service Recommended`. `Normal` when the field is absent. |
| `isBatteryDegraded` | boolean | True when the condition is present and is anything other than `Normal` (case-insensitive). |
| `sleepPrevented` | boolean | A `PreventUserIdleSystemSleep` or `PreventSystemSleep` assertion is held. |
| `sleepAssertionHolder` | string, key absent when nil | `caffeinate` or `WindowServer` when one of those is visible in the assertion list; the key is omitted otherwise. Not an exhaustive holder list. |
| `batteryDisplaySleepMinutes` | integer | `displaysleep` under `Battery Power`, minutes; `0` means never. |
| `batterySleepMinutes` | integer | `sleep` under `Battery Power`, minutes; `0` means never. |
| `acDisplaySleepMinutes` | integer | `displaysleep` under `AC Power`, minutes. |
| `acSleepMinutes` | integer | `sleep` under `AC Power`, minutes. |
| `sleepTimingsCoherent` | boolean | False when a display-sleep timer is longer than the system-sleep timer for the same power source, checked only where system sleep is enabled (`> 0`). An inverted pair asks the display to sleep after the machine already has. |
| `status` | string | `SERVICE_RECOMMENDED`, `INCOHERENT_SLEEP_TIMINGS`, `OPTIMAL_AC`, or `BATTERY_ACTIVE`, evaluated in that order. |

## disk

`DiskMetrics`. Sourced from `df -g /`, so all figures are whole gibibytes as
`df` reports them.

| Field | Type | Meaning |
| --- | --- | --- |
| `mountPoint` | string | Always `/` in this version. |
| `totalGB` | number | Volume size in GiB. |
| `freeGB` | number | Available space in GiB. |
| `percentFree` | number | `freeGB / totalGB × 100`; `0` when the total could not be parsed. |
| `status` | string | `AMPLE_SPACE` at ≥ 40 GiB free, otherwise `LOW_SPACE`. Note the readiness check below uses a stricter 45 GiB. |

## kernelExtensions

`KernelExtensionsMetrics`. Sourced from `kmutil showloaded` with `com.apple.*`
filtered out.

| Field | Type | Meaning |
| --- | --- | --- |
| `nonAppleKextsCount` | integer | Number of loaded non-Apple kexts. |
| `nonAppleKextNames` | array of string | Bundle identifiers, as parsed from the `kmutil` table. |
| `isCleanNative` | boolean | True when the list is empty. |
| `status` | string | `CLEAN_NATIVE` or `UNSAFE_LEGACY_KEXTS_LOADED`. |

## xcodeReadiness

`XcodeReadiness` — whether the machine can be handed a heavy compile right now.

| Field | Type | Meaning |
| --- | --- | --- |
| `isReady` | boolean | `diskSpaceAdequate && thermalsUnthrottled && powerConnected && gpuStable && windowServerHealthy && kernelExtensions.isCleanNative`. **`batteryHealthy` is deliberately not part of this conjunction** — a degraded battery produces a recommendation but does not withdraw readiness on AC power. |
| `diskSpaceAdequate` | boolean | `disk.freeGB >= 45`. |
| `thermalsUnthrottled` | boolean | `cpu.speedLimitPercent == 100 && !cpu.thermalWarning`. |
| `powerConnected` | boolean | `power.powerSource == "AC Charger"`. |
| `batteryHealthy` | boolean | `!power.isBatteryDegraded`. |
| `gpuStable` | boolean | `gpu.gpuSwitchSafe && gpu.activeIncidentsLastHour == 0`. |
| `windowServerHealthy` | boolean | `windowServer.isResponsive && windowServer.latencyMs < 500`. |
| `recommendations` | array of string | Human-readable, ordered by the checks above. When the mux is unsafe, this array carries the sentence that names the faulting GPU, cites the report count and restart channel, and gives the exact `pmset` command to park it. |

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | `OPTIMAL` |
| `1` | `DEGRADED_OR_WARNING` |
| `2` | `CRITICAL_ATTENTION_NEEDED` |
| `64` | Usage error (e.g. `--watch` without a positive interval). Follows the `sysexits.h` convention `EX_USAGE`. |
| `70` | The report could not be encoded to JSON. `EX_SOFTWARE`. Nothing is written to stdout in this case. |

`--version` and `--help` exit `0`. `pace` and the `sentinel` subcommands exit
`0` and do not carry a health verdict. `--watch` renders a dashboard forever
and therefore never returns a verdict at all.

## Example payload

Values below come from a live run on a 16" 2019 MacBook Pro (Intel UHD
Graphics 630 + AMD Radeon Pro 5300M) that had been throwing VMPT gpuRestarts;
the non-GPU sections are representative of that machine rather than captured
byte-for-byte.

```json
{
  "cpu" : {
    "logicalCores" : 12,
    "model" : "Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz",
    "physicalCores" : 6,
    "schedulerLimitPercent" : 100,
    "speedLimitPercent" : 100,
    "status" : "HEALTHY",
    "thermalWarning" : false
  },
  "disk" : {
    "freeGB" : 214,
    "mountPoint" : "\/",
    "percentFree" : 21.4,
    "status" : "AMPLE_SPACE",
    "totalGB" : 1000
  },
  "gpu" : {
    "activeIncidentsLastHour" : 0,
    "faultingGPU" : "AMD Radeon Pro 5300M",
    "faultingGPUIsDiscrete" : true,
    "gpuSwitchMode" : "Integrated Only (discrete GPU kept idle)",
    "gpuSwitchSafe" : true,
    "historicalIncidents24h" : 24,
    "hoursSinceLastCrash" : 7.2,
    "incidentsByGPU" : {
      "AMD Radeon Pro 5300M" : 21
    },
    "installedGPUs" : [
      {
        "isDiscrete" : false,
        "name" : "Intel UHD Graphics 630"
      },
      {
        "isDiscrete" : true,
        "name" : "AMD Radeon Pro 5300M"
      }
    ],
    "latestIncidentName" : "gpuRestart2026-08-19-223130.gpuRestart",
    "latestIncidentTime" : "10:31 PM",
    "restartChannels" : [
      "VMPT"
    ],
    "status" : "HISTORICAL_PANICS_RECORDED",
    "unattributedIncidents" : 3
  },
  "kernelExtensions" : {
    "isCleanNative" : true,
    "nonAppleKextNames" : [

    ],
    "nonAppleKextsCount" : 0,
    "status" : "CLEAN_NATIVE"
  },
  "memory" : {
    "freeGB" : 1.42,
    "pagesThrottled" : 0,
    "status" : "OPTIMAL",
    "swapFreeMB" : 892.5,
    "swapUsedMB" : 1155.5,
    "totalPhysicalGB" : 16
  },
  "overallHealth" : "DEGRADED_OR_WARNING",
  "power" : {
    "acDisplaySleepMinutes" : 10,
    "acSleepMinutes" : 0,
    "batteryCondition" : "Normal",
    "batteryDisplaySleepMinutes" : 2,
    "batteryPercentage" : 100,
    "batterySleepMinutes" : 10,
    "isBatteryDegraded" : false,
    "powerSource" : "AC Charger",
    "sleepPrevented" : false,
    "sleepTimingsCoherent" : true,
    "status" : "OPTIMAL_AC"
  },
  "schemaVersion" : 1,
  "timestamp" : "2026-08-20T05:43:02Z",
  "toolVersion" : "1.1.0",
  "windowServer" : {
    "cpuPercent" : 4.7,
    "isResponsive" : true,
    "latencyMs" : 18.4,
    "sleepAssertionHolder" : false,
    "status" : "RESPONSIVE"
  },
  "xcodeReadiness" : {
    "batteryHealthy" : true,
    "diskSpaceAdequate" : true,
    "gpuStable" : true,
    "isReady" : true,
    "powerConnected" : true,
    "recommendations" : [

    ],
    "thermalsUnthrottled" : true,
    "windowServerHealthy" : true
  }
}
```

Read that payload the way the tool does: 21 of the last 24 reports name the
AMD dGPU on the VMPT channel, so `faultingGPU` is the AMD part; the machine is
already on `gpuswitch 0`, which parks exactly that part, so `gpuSwitchSafe` is
true and readiness survives. The verdict is still `DEGRADED_OR_WARNING`
because incidents happened inside the 24-hour window — the mitigation is
holding, but the hardware is still faulting.

## Consuming this from a script

Attribution in one line, with the schema gate:

```bash
mac-health --json | jq -e '
  if .schemaVersion > 1 then error("unsupported schemaVersion") else
    { verdict: .overallHealth,
      faulting: .gpu.faultingGPU,
      incidents: .gpu.historicalIncidents24h,
      muxSafe: .gpu.gpuSwitchSafe }
  end'
```

Note that `mac-health` exits non-zero on a degraded machine, so a pipeline
under `set -e` needs `set -o pipefail` off, or the exit code captured
explicitly as below.

An MDM-style check that distinguishes "unhealthy machine" from "broken tool":

```bash
#!/bin/sh
# Exit 0 = healthy, 1 = needs attention, 2 = escalate, anything else = the
# check itself failed and the result must not be treated as a health signal.
report=$(mac-health --json)
status=$?

case "$status" in
  0) exit 0 ;;
  1|2)
    printf '%s\n' "$report" | jq -r '
      "\(.overallHealth): \(.xcodeReadiness.recommendations | join(" "))"' >&2
    exit "$status"
    ;;
  64|70)
    echo "mac-health could not produce a report (exit $status)" >&2
    exit 3
    ;;
  *)
    echo "mac-health exited unexpectedly ($status)" >&2
    exit 3
    ;;
esac
```

See [incident-playbooks.md](incident-playbooks.md) for what to do once a
payload says something is wrong.
