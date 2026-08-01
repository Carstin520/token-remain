#!/usr/bin/env swift

import Darwin
import Foundation

struct Arguments {
    let pid: Int32
    let duration: TimeInterval
    let samples: Int

    init(_ values: [String]) throws {
        func value(after flag: String) -> String? {
            guard let index = values.firstIndex(of: flag), values.indices.contains(index + 1) else {
                return nil
            }
            return values[index + 1]
        }

        guard let rawPID = value(after: "--pid"), let pid = Int32(rawPID), pid > 0 else {
            throw NSError(
                domain: "TokenRemainEnergyProbe",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Usage: measure_process_energy.swift --pid <pid> [--duration 10] [--samples 3]"]
            )
        }
        let duration = value(after: "--duration").flatMap(Double.init) ?? 10
        let samples = value(after: "--samples").flatMap(Int.init) ?? 3
        guard (1...60).contains(duration), (1...20).contains(samples) else {
            throw NSError(
                domain: "TokenRemainEnergyProbe",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Duration must be 1...60 seconds and samples must be 1...20."]
            )
        }
        self.pid = pid
        self.duration = duration
        self.samples = samples
    }
}

struct Snapshot {
    let usage: rusage_info_v6
    let readAt: Date
}

struct Result {
    let elapsed: TimeInterval
    let energyJoules: Double
    let cpuSeconds: Double
    let packageIdleWakeups: UInt64
    let interruptWakeups: UInt64

    var averagePowerWatts: Double { energyJoules / elapsed }
    var averageCPUPercent: Double { cpuSeconds / elapsed * 100 }
    var packageIdleWakeupsPerSecond: Double { Double(packageIdleWakeups) / elapsed }
    var interruptWakeupsPerSecond: Double { Double(interruptWakeups) / elapsed }
}

func readUsage(pid: Int32) throws -> Snapshot {
    var usage = rusage_info_v6()
    let status = withUnsafeMutablePointer(to: &usage) { pointer in
        proc_pid_rusage(
            pid,
            RUSAGE_INFO_V6,
            UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self)
        )
    }
    guard status == 0 else {
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "proc_pid_rusage(\(pid)) failed"]
        )
    }
    return Snapshot(usage: usage, readAt: .now)
}

func delta(from start: Snapshot, to end: Snapshot, ticksToSeconds: Double) -> Result {
    let startCPU = start.usage.ri_user_time + start.usage.ri_system_time
    let endCPU = end.usage.ri_user_time + end.usage.ri_system_time
    return Result(
        elapsed: end.readAt.timeIntervalSince(start.readAt),
        energyJoules: Double(end.usage.ri_energy_nj - start.usage.ri_energy_nj) / 1_000_000_000,
        cpuSeconds: Double(endCPU - startCPU) * ticksToSeconds,
        packageIdleWakeups: end.usage.ri_pkg_idle_wkups - start.usage.ri_pkg_idle_wkups,
        interruptWakeups: end.usage.ri_interrupt_wkups - start.usage.ri_interrupt_wkups
    )
}

do {
    let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticksToSeconds = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    var results: [Result] = []

    print("pid,sample,seconds,energy_joules,average_power_watts,cpu_percent,package_idle_wakeups_per_second,interrupt_wakeups_per_second")
    for sample in 1...arguments.samples {
        let start = try readUsage(pid: arguments.pid)
        Thread.sleep(forTimeInterval: arguments.duration)
        let result = delta(
            from: start,
            to: try readUsage(pid: arguments.pid),
            ticksToSeconds: ticksToSeconds
        )
        results.append(result)
        print(String(
            format: "%d,%d,%.3f,%.6f,%.6f,%.3f,%.3f,%.3f",
            arguments.pid,
            sample,
            result.elapsed,
            result.energyJoules,
            result.averagePowerWatts,
            result.averageCPUPercent,
            result.packageIdleWakeupsPerSecond,
            result.interruptWakeupsPerSecond
        ))
        fflush(stdout)
    }

    let elapsed = results.reduce(0) { $0 + $1.elapsed }
    let totalEnergy = results.reduce(0) { $0 + $1.energyJoules }
    let totalCPU = results.reduce(0) { $0 + $1.cpuSeconds }
    let totalPackageWakeups = results.reduce(UInt64(0)) { $0 + $1.packageIdleWakeups }
    let totalInterruptWakeups = results.reduce(UInt64(0)) { $0 + $1.interruptWakeups }
    print(String(
        format: "summary,%d,%.3f,%.6f,%.6f,%.3f,%.3f,%.3f",
        arguments.samples,
        elapsed,
        totalEnergy,
        totalEnergy / elapsed,
        totalCPU / elapsed * 100,
        Double(totalPackageWakeups) / elapsed,
        Double(totalInterruptWakeups) / elapsed
    ))
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(2)
}
