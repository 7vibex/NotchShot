import Foundation
import NotchShotAIReporterSupport
import NotchShotKit

/// Measurement coverage for the activity-island paths: engine sync and
/// presentation resolution at 1, 3 and 8 activities, progress-only updates that
/// must keep structural identity, the transfer store's publication cadence
/// under a byte burst, and the external registry's update and rejection work.
@MainActor
enum IslandBenchmarks {
    static let t0 = Date(timeIntervalSince1970: 7_000_000)

    private static func activities(_ count: Int) -> [IslandActivity] {
        (0 ..< count).map { index in
            IslandActivity(
                id: IslandActivityID(kind: index == 0 ? .recording : .external, key: "bench-\(index)"),
                priority: index == 0 ? .critical : .normal,
                relevance: 0.5,
                progress: .indeterminate,
                startedAt: t0,
                title: "Activity \(index)",
                symbolName: "gear",
                accentHex: "#7CC4FF"
            )
        }
    }

    static func run(enabled: (String) -> Bool) {
        if enabled("island.engine") {
            let configuration = IslandEngineConfiguration(maximumVisibleActivities: 3, expandsOnHover: true)
            for count in [1, 3, 8] {
                let incoming = activities(count)
                var engine = IslandPresentationEngine()
                let sync = engine.sync(incoming, now: t0)
                precondition(sync.inserted.count == count, "engine lost activities on sync")
                let presentation = engine.present(
                    configuration: configuration,
                    isHoverPreviewing: false,
                    now: t0
                )
                precondition(presentation.primary != nil, "engine resolved no primary")
                precondition(
                    (1 ... count).contains(presentation.visibleActivities.count),
                    "engine resolved an impossible visible set"
                )

                Benchmark.measure("island.sync \(count) activities", iterations: 50, warmup: 5) {
                    var local = IslandPresentationEngine()
                    Benchmark.blackHole(local.sync(incoming, now: t0))
                }
                Benchmark.measure("island.present \(count) activities", iterations: 50, warmup: 5) {
                    var local = engine
                    Benchmark.blackHole(local.present(
                        configuration: configuration,
                        isHoverPreviewing: false,
                        now: t0
                    ))
                }
            }

            // A progress-only update (metric + updatedAt) must keep structural
            // identity: no insert, no remove, no lifecycle change, and a stable
            // descriptor. Only then is it fair to assume the presentation path
            // stays cheap.
            var shared = activities(8)
            shared[0].metric = "1%"
            var engine = IslandPresentationEngine()
            _ = engine.sync(shared, now: t0)
            let resolvedBefore = engine.present(
                configuration: configuration,
                isHoverPreviewing: false,
                now: t0
            ).descriptor()
            for index in shared.indices {
                shared[index].metric = "\(index + 11)%"
                shared[index].updatedAt = t0.addingTimeInterval(Double(index + 1))
            }
            var probe = engine
            let progressSync = probe.sync(shared, now: t0.addingTimeInterval(1))
            precondition(!progressSync.isStructural, "progress-only update changed island structure")
            let resolvedAfter = probe.present(
                configuration: configuration,
                isHoverPreviewing: false,
                now: t0.addingTimeInterval(1)
            ).descriptor()
            precondition(
                resolvedBefore == resolvedAfter,
                "progress-only update changed the presentation descriptor"
            )

            Benchmark.measure("island.sync 8 progress-only", iterations: 50, warmup: 5) {
                var local = engine
                Benchmark.blackHole(local.sync(shared, now: t0.addingTimeInterval(1)))
            }
            Benchmark.measure("island.present 8 progress-only", iterations: 50, warmup: 5) {
                var local = probe
                Benchmark.blackHole(local.present(
                    configuration: configuration,
                    isHoverPreviewing: false,
                    now: t0.addingTimeInterval(1)
                ))
            }

            // Promotion between primary and satellite, and expand/collapse.
            var promotion = IslandPresentationEngine()
            let set = activities(3)
            _ = promotion.sync(set, now: t0)
            _ = promotion.present(configuration: configuration, isHoverPreviewing: false, now: t0)
            let satellite = set[1].id
            Benchmark.measure("island.promote satellite", iterations: 50, warmup: 5) {
                var local = promotion
                _ = local.select(satellite, now: t0)
                Benchmark.blackHole(local.present(
                    configuration: configuration,
                    isHoverPreviewing: false,
                    now: t0
                ))
            }
            Benchmark.measure("island.expand+collapse", iterations: 50, warmup: 5) {
                var local = promotion
                local.expand(satellite)
                _ = local.present(configuration: configuration, isHoverPreviewing: true, now: t0)
                local.collapse()
                Benchmark.blackHole(local.present(
                    configuration: configuration,
                    isHoverPreviewing: false,
                    now: t0
                ))
            }
        }

        if enabled("island.transferStore") {
            let store = TransferActivityStore()
            let id = store.begin(
                service: .localSend,
                peerName: "Phone",
                fileCount: 1,
                totalBytes: 10_000_000,
                now: t0
            )
            var publications = 0
            var rawUpdates = 0
            store.onChange = { publications += 1 }
            let iterations = 5
            let warmup = 1
            let perIteration = 2_000
            Benchmark.measure(
                "transferStore 10k progress updates",
                iterations: iterations,
                warmup: warmup
            ) {
                for _ in 0 ..< perIteration {
                    rawUpdates += 1
                    store.update(
                        id,
                        completedFiles: 0,
                        currentFilename: "payload.bin",
                        bytesTransferred: Int64(rawUpdates),
                        now: t0.addingTimeInterval(Double(rawUpdates) * 0.001)
                    )
                }
            }
            precondition(rawUpdates == (iterations + warmup) * perIteration)
            precondition(publications < rawUpdates, "progress updates published one-for-one")
            // The final progress lands on the trailing edge of the throttle
            // window; spin the main run loop so that task can run before the
            // benchmark asserts on the published snapshot.
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            precondition(
                store.transfers.first?.bytesTransferred == Int64(rawUpdates),
                "the final progress value was not published"
            )
            print("  transfer store: \(rawUpdates) raw updates → \(publications) publications")
            store.dismiss(id)
        }

        if enabled("external.registry") {
            // Sustained valid updates, with the token bucket widened so every
            // merge is accepted: this measures registry work, not rejection.
            var wideLimits = ExternalActivityRegistry.Limits()
            wideLimits.messagesPerSecond = 1_000_000
            wideLimits.burst = 1_000_000
            var registry = ExternalActivityRegistry(limits: wideLimits)
            _ = registry.apply(
                LiveActivityUpdate(command: .start, id: "sustained", title: "Sustained"),
                now: t0
            )
            let update = LiveActivityUpdate(command: .update, id: "sustained", title: nil, progress: 0.5)
            Benchmark.measure("registry 10k accepted merges", iterations: 5, warmup: 1) {
                var local = registry
                for step in 0 ..< 2_000 {
                    _ = local.apply(update, now: t0.addingTimeInterval(Double(step) * 0.001))
                }
                Benchmark.blackHole(local.live.count)
            }

            // Rejection behavior: the default bucket accepts the burst and then
            // rejects until it refills. The counts are the oracle.
            var bucket = ExternalActivityRegistry()
            _ = bucket.apply(
                LiveActivityUpdate(command: .start, id: "bucket", title: "Bucket"),
                now: t0
            )
            let bucketUpdate = LiveActivityUpdate(
                command: .update,
                id: "bucket",
                title: nil,
                progress: 0.5
            )
            var accepted = 0
            var rejected = 0
            Benchmark.measure("registry 10k rate-limited attempts", iterations: 5, warmup: 1) {
                var local = bucket
                for _ in 0 ..< 2_000 {
                    if local.apply(bucketUpdate, now: t0) == nil { accepted += 1 } else { rejected += 1 }
                }
                Benchmark.blackHole(local.live.count)
            }
            precondition(accepted + rejected == 12_000)
            // The start consumed one token, so each fresh copy of the bucket
            // accepts exactly 39 updates at the same instant.
            requireExactly(39 * 6, accepted, "the default burst is the only acceptance at a fixed instant")
            print("  registry bucket: \(accepted + rejected) attempts → \(accepted) accepted, \(rejected) rejected")

            // Thousands of completed activities stay bounded.
            let completions = ExternalActivityRegistry()
            Benchmark.measure("registry 5k completions stay bounded", iterations: 3, warmup: 1) {
                var local = completions
                for index in 0 ..< 5_000 {
                    let now = t0.addingTimeInterval(Double(index))
                    _ = local.apply(
                        LiveActivityUpdate(command: .finish, id: "done-\(index)", title: "Done"),
                        now: now
                    )
                    _ = local.expire(now: now)
                }
                Benchmark.blackHole(local.history.count)
                precondition(local.live.isEmpty)
                precondition(local.history.count <= local.limits.maximumHistory)
            }
        }
    }

    private static func requireExactly(_ expected: Int, _ actual: Int, _ message: String = "") {
        precondition(actual == expected, message.isEmpty ? "expected \(expected), got \(actual)" : message)
    }
}
