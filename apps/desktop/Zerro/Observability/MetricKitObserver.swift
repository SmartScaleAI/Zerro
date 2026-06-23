//
//  MetricKitObserver.swift
//  Zerro
//
//  MetricKit → PostHog bridge for crash/hang/exception DIAGNOSTICS.
//
//  Why this exists alongside PostHog's own error tracking
//  ------------------------------------------------------
//  PostHog's crash autocapture (configured in `Analytics.start()`) sees Mach
//  exceptions / POSIX signals, but a pure-Swift fatal (force-unwrap, array
//  out-of-bounds, `fatalError`) surfaces there as a bare SIGTRAP with no
//  message — you learn the app died, not why. MetricKit's crash diagnostics
//  carry the OS-supplied `terminationReason` (often the real Swift fault
//  text), plus hang and CPU/disk-write exceptions PostHog never observes.
//  Forwarding these as events fills exactly that blind spot.
//
//  MetricKit delivers payloads on a BACKGROUND queue, batched and DELAYED
//  (typically once every 24h — a payload can describe a crash from a build
//  the user is no longer running). Two consequences drive the design below:
//    • the delegate methods are `nonisolated` (match the SCStreamDelegate
//      idiom) and hop to the MainActor only to reach `Analytics.capture`;
//    • each event carries the build/OS the diagnostic CAME FROM
//      (`metaData`), never the current session's — otherwise a day-old crash
//      would be misattributed to today's build.
//
//  Privacy contract (same as Analytics.swift)
//  ------------------------------------------
//  Only BOUNDED metadata leaves here — enums, numeric codes, bucketed
//  durations/sizes, and the payload's build/OS strings. The one deliberate
//  exception is `terminationReason`, which can in principle embed a path: it
//  is TRUNCATED to `maxTerminationReasonChars` and treated as diagnostic
//  metadata. The full, unsymbolicated `callStackTree` JSON is NEVER sent as a
//  property (large, low-value, and a PostHog property-size risk) — it is
//  logged once on-device at `.private` for deep debugging only.
//
//  Forwarding goes through `Analytics.capture` (NOT PostHogSDK directly) so it
//  inherits the consent-toggle gate and the DEBUG no-op for free.
//

import Foundation
import MetricKit
import os

/// Subscribes to `MXMetricManager` and forwards each diagnostic as one
/// `metrickit_diagnostic` PostHog event. Registered (and retained) for the
/// app's lifetime by `ZerroApp` — `MXMetricManager` holds only a weak
/// reference to its subscribers.
final class MetricKitObserver: NSObject, MXMetricManagerSubscriber {

    /// Termination reasons can be long and may embed a path — cap them so the
    /// event stays bounded metadata, not content.
    nonisolated private static let maxTerminationReasonChars = 150

    /// On-device only (never transmitted): the unsymbolicated call-stack JSON,
    /// logged at `.private` so it's available when attaching a debugger /
    /// collecting a sysdiagnose, but redacted in anyone-else's-machine logs.
    nonisolated private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.cbreeding.Zerro",
        category: "metrickit"
    )

    // MARK: - Metric payloads (intentionally unused)

    /// Part of the subscriber protocol. We only want diagnostics, not the
    /// aggregate daily metrics (CPU/memory/launch-time histograms), so this is
    /// deliberately empty.
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {}

    // MARK: - Diagnostic payloads

    /// Each payload bundles zero-or-more diagnostics of four kinds. We flatten
    /// them into one bounded event apiece, building the (Sendable) property
    /// dictionaries here on MetricKit's delivery queue, then hop to the
    /// MainActor once to push them through the `Analytics` chokepoint.
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var events: [[String: String]] = []
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                logCallStack(crash.callStackTree, kind: "crash")
                events.append(crashEvent(crash))
            }
            for hang in payload.hangDiagnostics ?? [] {
                logCallStack(hang.callStackTree, kind: "hang")
                events.append(hangEvent(hang))
            }
            for cpu in payload.cpuExceptionDiagnostics ?? [] {
                logCallStack(cpu.callStackTree, kind: "cpu_exception")
                events.append(cpuEvent(cpu))
            }
            for disk in payload.diskWriteExceptionDiagnostics ?? [] {
                logCallStack(disk.callStackTree, kind: "disk_write_exception")
                events.append(diskWriteEvent(disk))
            }
        }
        guard !events.isEmpty else { return }
        // Snapshot into an immutable `let` so the concurrently-executing Task
        // captures a value, not the mutable `var` (a Swift 6 error otherwise).
        let captured = events
        Task { @MainActor in
            for properties in captured {
                Analytics.capture("metrickit_diagnostic", properties)
            }
        }
    }

    // MARK: - Per-kind event builders

    /// Build/OS the diagnostic was generated on — NOT the current session's.
    /// Named `diagnostic_*` to avoid being confused with the live `app_version`
    /// super-property, since payloads arrive delayed (up to a day later).
    nonisolated private func baseProperties(_ diagnostic: MXDiagnostic, kind: String) -> [String: String] {
        [
            "kind": kind,
            "diagnostic_build": diagnostic.metaData.applicationBuildVersion,
            "diagnostic_os_version": diagnostic.metaData.osVersion,
        ]
    }

    nonisolated private func crashEvent(_ d: MXCrashDiagnostic) -> [String: String] {
        var properties = baseProperties(d, kind: "crash")
        if let exceptionType = d.exceptionType {
            properties["exception_type"] = String(exceptionType.intValue)
        }
        if let exceptionCode = d.exceptionCode {
            properties["exception_code"] = String(exceptionCode.intValue)
        }
        if let signal = d.signal {
            properties["signal"] = String(signal.intValue)
        }
        if let reason = d.terminationReason {
            // Deliberate, scoped exception to the no-content rule: truncated and
            // treated as diagnostic metadata (it's often the real Swift fault).
            properties["termination_reason"] = String(reason.prefix(Self.maxTerminationReasonChars))
        }
        return properties
    }

    nonisolated private func hangEvent(_ d: MXHangDiagnostic) -> [String: String] {
        var properties = baseProperties(d, kind: "hang")
        let seconds = d.hangDuration.converted(to: .seconds).value
        properties["hang_duration_bucket"] = hangBucket(seconds)
        return properties
    }

    nonisolated private func cpuEvent(_ d: MXCPUExceptionDiagnostic) -> [String: String] {
        var properties = baseProperties(d, kind: "cpu_exception")
        let seconds = d.totalCPUTime.converted(to: .seconds).value
        properties["cpu_time_bucket"] = cpuSecondsBucket(seconds)
        return properties
    }

    nonisolated private func diskWriteEvent(_ d: MXDiskWriteExceptionDiagnostic) -> [String: String] {
        var properties = baseProperties(d, kind: "disk_write_exception")
        let bytes = d.totalWritesCaused.converted(to: .bytes).value
        properties["writes_bucket"] = byteBucket(bytes)
        return properties
    }

    // MARK: - Coarse bucketing (never the raw measurement)

    nonisolated private func hangBucket(_ seconds: Double) -> String {
        switch seconds {
        case ..<2:   return "<2s"
        case ..<5:   return "2-5s"
        case ..<10:  return "5-10s"
        default:     return "10s+"
        }
    }

    nonisolated private func cpuSecondsBucket(_ seconds: Double) -> String {
        switch seconds {
        case ..<30:  return "<30s"
        case ..<60:  return "30-60s"
        case ..<180: return "60-180s"
        default:     return "180s+"
        }
    }

    nonisolated private func byteBucket(_ bytes: Double) -> String {
        let megabytes = bytes / 1_000_000
        switch megabytes {
        case ..<256:  return "<256MB"
        case ..<1024: return "256MB-1GB"
        case ..<4096: return "1-4GB"
        default:      return "4GB+"
        }
    }

    // MARK: - On-device call-stack dump

    /// Logs the call-stack JSON once at `.private` (stays on-device) so a
    /// forwarded event can be paired with a stack during deep debugging,
    /// without ever shipping the large unsymbolicated blob to PostHog.
    nonisolated private func logCallStack(_ tree: MXCallStackTree, kind: String) {
        let json = String(decoding: tree.jsonRepresentation(), as: UTF8.self)
        Self.log.debug("metrickit \(kind, privacy: .public) call stack: \(json, privacy: .private)")
    }
}
