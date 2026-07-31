# TokenRemain 1.2.3 energy validation

This note records the reproducible hidden-idle comparison that drove the
TokenRemain 1.2.3 performance work. It is a process-level engineering
measurement, not a battery-runtime claim.

## Test environment

- MacBook Pro `Mac17,9`, Apple M5 Pro (18 cores), 64 GB memory
- macOS 26.5.2 (25F84)
- Dashboard created once and then closed; menu-bar process remained running
- A Codex session was active, so the optimized build exercised its worst-case
  one-minute refresh cadence rather than the five-minute idle cadence

## Measurement method

`script/measure_process_energy.swift` samples `proc_pid_rusage` using
`RUSAGE_INFO_V6`. CPU time is converted from Mach absolute-time ticks;
`ri_energy_nj`, package-idle wakeups, and interrupt wakeups are measured as
counter deltas over each interval.

Example:

```sh
swift script/measure_process_energy.swift --pid <pid> --duration 10 --samples 7
```

The baseline used two settled ten-second samples from the installed public
1.2.2 Release build. The 1.2.3 candidate used seven ten-second samples and
intentionally crossed a complete 60-second active-session refresh boundary.
Both rows use optimized Universal Release executables; the 1.2.3 row is the
Developer ID-signed build extracted from its release ZIP before publication.

## Result

| Hidden-Dashboard process | Average CPU | Attributed average power | Interrupt wakeups |
| --- | ---: | ---: | ---: |
| Public 1.2.2 (build 16) | 9.65% | 31.6 mW | 64.0/s |
| Signed 1.2.3 (build 17) | 0.449% | 7.336 mW | 2.769/s |
| Reduction | 95.3% | 76.8% | 95.7% |

The dominant 1.2.2 stack was SwiftUI's animation timeline repeatedly laying
out and compositing the Dashboard robot after its window had closed. Pausing
that timeline removed the continuous load. Session-aware scheduling and the
Codex metadata/parse cache then bounded the periodic refresh work.

## Experience boundary

- The robot keeps the same 0.22-second stepped animation while onscreen.
- A newly active Codex or Claude session is detected through filesystem events;
  the cheap activity probe returns the refresh loop to minute cadence within
  one minute. Session roots created after TokenRemain launches are picked up by
  that same probe and seeded before monitoring continues.
- With no recent local session and no visible primary surface, quota and local
  usage work falls back to at least five minutes. Manual refresh remains
  immediate, and Apple devices continue receiving snapshots through the
  existing Mac publish path.
- Enabled providers outside Codex and Claude retain the refresh interval the
  user selected. Presenting or uncovering a primary surface immediately runs a
  due check, so stale quota data catches up without forcing already-fresh
  provider requests.
- CPU and energy counters are machine- and workload-specific. They support the
  before/after diagnosis on this Mac and should not be extrapolated directly to
  battery hours on other hardware.
