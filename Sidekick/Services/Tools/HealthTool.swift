import Foundation
import HealthKit

struct HealthSummaryTool: AgentTool {
    let name = "get_health_summary"
    let description = "Summarize the user's Apple Health data for the last N days: steps, active energy, exercise minutes, resting heart rate, sleep. Use for health check-ins, coaching and trend questions."
    let parameters = JSONSchema.object([
        "days": JSONSchema.integer("Number of past days to include (1-30). Default 7."),
    ])

    func summary(for args: JSONValue) -> String { "Reading your Apple Health data" }

    func run(args: JSONValue, context: ToolContext) async throws -> String {
        guard HKHealthStore.isHealthDataAvailable() else { return "Health data is not available on this device." }
        let days = min(max(args["days"]?.intValue ?? 7, 1), 30)
        let store = HKHealthStore()

        let steps = HKQuantityType(.stepCount)
        let energy = HKQuantityType(.activeEnergyBurned)
        let exercise = HKQuantityType(.appleExerciseTime)
        let restingHR = HKQuantityType(.restingHeartRate)
        let sleep = HKCategoryType(.sleepAnalysis)
        try await store.requestAuthorization(toShare: [], read: [steps, energy, exercise, restingHR, sleep])

        let end = Calendar.current.startOfDay(for: .now).addingTimeInterval(86_400)
        let start = end.addingTimeInterval(Double(-days) * 86_400)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)

        var lines: [String] = ["Apple Health summary for the last \(days) day(s):"]
        lines.append(await Self.dailyStat(store, type: steps, unit: .count(), start: start, end: end, label: "Steps", format: "%.0f"))
        lines.append(await Self.dailyStat(store, type: energy, unit: .kilocalorie(), start: start, end: end, label: "Active energy (kcal)", format: "%.0f"))
        lines.append(await Self.dailyStat(store, type: exercise, unit: .minute(), start: start, end: end, label: "Exercise minutes", format: "%.0f"))
        lines.append(await Self.averageStat(store, type: restingHR, unit: HKUnit.count().unitDivided(by: .minute()), predicate: predicate, label: "Resting heart rate (bpm)"))
        lines.append(await Self.sleepStat(store, type: sleep, predicate: predicate, days: days))
        return lines.joined(separator: "\n")
    }

    private static func dailyStat(_ store: HKHealthStore, type: HKQuantityType, unit: HKUnit, start: Date, end: Date, label: String, format: String) async -> String {
        await withCheckedContinuation { cont in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
            let anchor = Calendar.current.startOfDay(for: .now)
            let q = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum, anchorDate: anchor, intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, results, error in
                guard let results, error == nil else {
                    cont.resume(returning: "- \(label): unavailable"); return
                }
                var values: [String] = []
                var total = 0.0
                results.enumerateStatistics(from: start, to: end) { stat, _ in
                    let v = stat.sumQuantity()?.doubleValue(for: unit) ?? 0
                    total += v
                    values.append(String(format: format, v))
                }
                let avg = values.isEmpty ? 0 : total / Double(values.count)
                cont.resume(returning: "- \(label): daily avg \(String(format: format, avg)), per day [\(values.joined(separator: ", "))]")
            }
            store.execute(q)
        }
    }

    private static func averageStat(_ store: HKHealthStore, type: HKQuantityType, unit: HKUnit, predicate: NSPredicate, label: String) async -> String {
        await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .discreteAverage) { _, stat, _ in
                if let v = stat?.averageQuantity()?.doubleValue(for: unit) {
                    cont.resume(returning: "- \(label): avg \(String(format: "%.0f", v))")
                } else {
                    cont.resume(returning: "- \(label): no data")
                }
            }
            store.execute(q)
        }
    }

    private static func sleepStat(_ store: HKHealthStore, type: HKCategoryType, predicate: NSPredicate, days: Int) async -> String {
        await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                let asleep = (samples as? [HKCategorySample] ?? []).filter {
                    HKCategoryValueSleepAnalysis.allAsleepValues.contains(HKCategoryValueSleepAnalysis(rawValue: $0.value) ?? .awake)
                }
                let hours = asleep.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) } / 3600
                if asleep.isEmpty { cont.resume(returning: "- Sleep: no data") }
                else { cont.resume(returning: "- Sleep: avg \(String(format: "%.1f", hours / Double(days))) h/night") }
            }
            store.execute(q)
        }
    }
}
