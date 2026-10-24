import SwiftUI
import Observation
import IOKit.ps

/// CPU, memory and battery — sampled only while the System tab is on screen.
/// Nothing here runs in the background; a monitor that costs battery to tell
/// you about battery would be a poor joke.
@MainActor
@Observable
final class SystemMonitor {
    private(set) var cpu: Double = 0
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryUsed: Double = 0
    let memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
    private(set) var battery: Int?
    private(set) var charging = false
    private(set) var thermal: ProcessInfo.ThermalState = .nominal

    let mac = MacInfo.current

    private var timer: Timer?
    private var previousTicks: [UInt32]?

    func setVisible(_ visible: Bool) {
        if visible, timer == nil {
            sample()
            let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            t.tolerance = 0.3
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !visible {
            timer?.invalidate()
            timer = nil
        }
    }

    private func sample() {
        if let load = cpuLoad() {
            cpu = load
            cpuHistory.append(load)
            if cpuHistory.count > 40 { cpuHistory.removeFirst(cpuHistory.count - 40) }
        }
        memoryUsed = usedMemory()
        (battery, charging) = batteryState()
        thermal = ProcessInfo.processInfo.thermalState
    }

    /// Busy share of all cores since the previous sample, from the kernel's
    /// per-core tick counters (user, system, idle, nice).
    private func cpuLoad() -> Double? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let ticks = (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
        defer { previousTicks = ticks }
        guard let previous = previousTicks, previous.count == ticks.count else { return nil }

        var busy: UInt64 = 0, total: UInt64 = 0
        let stride = Int(CPU_STATE_MAX)
        for core in 0..<Int(count) {
            for state in 0..<stride {
                let i = core * stride + state
                let delta = UInt64(ticks[i] &- previous[i])
                total += delta
                if state != Int(CPU_STATE_IDLE) { busy += delta }
            }
        }
        return total == 0 ? 0 : Double(busy) / Double(total)
    }

    /// "Used" the way Activity Monitor counts it: app memory + wired + compressed.
    private func usedMemory() -> Double {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return memoryUsed }
        let page = Double(vm_kernel_page_size)
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        return (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
    }

    private func batteryState() -> (Int?, Bool) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return (nil, false) }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let level = d[kIOPSCurrentCapacityKey] as? Int
            else { continue }
            return (level, d[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return (nil, false)
    }
}

/// Which Mac this is: the model identifier, the chip, and whether the display
/// has a notch — which decides how the island is drawn.
struct MacInfo {
    var model: String
    var chip: String
    var cores: Int

    static let current = MacInfo(
        model: sysctl("hw.model") ?? "Mac",
        chip: sysctl("machdep.cpu.brand_string") ?? "Apple silicon",
        cores: ProcessInfo.processInfo.activeProcessorCount
    )

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

struct SystemTab: View {
    let model: IslandModel
    private var system: SystemMonitor { model.system }
    private var accent: Color { model.settings.accent.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                gauge("CPU", value: system.cpu, detail: "\(system.mac.cores) cores") {
                    Sparkline(values: system.cpuHistory, color: accent)
                        .frame(height: 26)
                }
                gauge("Memory", value: system.memoryUsed / max(1, system.memoryTotal),
                      detail: "\(gb(system.memoryUsed)) of \(gb(system.memoryTotal))") { EmptyView() }
                if let level = system.battery {
                    gauge("Battery", value: Double(level) / 100,
                          detail: system.charging ? "Charging" : "On battery",
                          color: level <= 20 && !system.charging ? .red : .green) { EmptyView() }
                }
                if model.claude.available {
                    ClaudeTile(usage: model.claude, accent: accent)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                info("desktopcomputer", system.mac.chip)
                info("number", system.mac.model)
                info(model.geometry.hasNotch ? "rectangle.topthird.inset.filled" : "rectangle", model.geometry.hasNotch ? "Notch display" : "No notch")
                if system.thermal != .nominal {
                    info("thermometer.medium", thermalText).foregroundStyle(.orange)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var thermalText: String {
        switch system.thermal {
        case .fair: "Warm"
        case .serious: "Hot — throttling"
        case .critical: "Critical heat"
        default: "Cool"
        }
    }

    private func gauge<Extra: View>(_ title: String, value: Double, detail: String, color: Color? = nil, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
            Text(value, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: value))
                .animation(.spring(response: 0.4, dampingFraction: 1), value: value)
            ProgressView(value: min(1, max(0, value)))
                .tint(color ?? accent)
            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            extra()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
    }

    private func info(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).lineLimit(1)
    }

    private func gb(_ bytes: Double) -> String {
        String(format: "%.1f GB", bytes / 1_073_741_824)
    }
}

struct Sparkline: View {
    var values: [Double]
    var color: Color

    var body: some View {
        GeometryReader { geo in
            Path { p in
                guard values.count > 1 else { return }
                let step = geo.size.width / CGFloat(values.count - 1)
                for (i, v) in values.enumerated() {
                    let point = CGPoint(x: CGFloat(i) * step, y: geo.size.height * (1 - CGFloat(min(1, v))))
                    i == 0 ? p.move(to: point) : p.addLine(to: point)
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}
