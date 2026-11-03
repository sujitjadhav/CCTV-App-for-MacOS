import AppKit
import SwiftUI

// Device information read from the NVR over DVRIP (read-only: nothing is changed on the NVR).

struct InfoRow: Identifiable, Hashable {
    var id: String { label }
    let label: String
    let value: String
}

struct DiskInfo: Identifiable, Hashable {
    let id: Int
    let totalMB: Double
    let freeMB: Double
    let status: String
    let readWrite: Bool
    let current: Bool
    var usedMB: Double { max(0, totalMB - freeMB) }
    var fraction: Double { totalMB > 0 ? usedMB / totalMB : 0 }
}

final class DeviceModel: ObservableObject {
    static let shared = DeviceModel()

    @Published var loading = false
    @Published var error: String?
    @Published var updated: Date?
    @Published var system: [InfoRow] = []
    @Published var device: [InfoRow] = []
    @Published var network: [InfoRow] = []
    @Published var recording: [InfoRow] = []
    @Published var general: [InfoRow] = []
    @Published var disks: [DiskInfo] = []
    @Published var raw: [InfoRow] = []          // every SystemInfo value, for "All values"
    @Published var title = "NVR"
    @Published var online = false

    func load() {
        guard !loading else { return }
        loading = true
        error = nil
        Task { @MainActor in
            do {
                let c = try await DVRIPClient.connected()
                defer { c.close() }
                // Each query is optional: older firmware may not answer all of them.
                let sys = (try? await c.systemInfo()) ?? [:]
                let time = try? await c.deviceTime()
                let storage = (try? await c.get("StorageInfo")) as? [[String: Any]] ?? []
                let gen = (try? await c.get("General.General", msg: 1042)) as? [String: Any] ?? [:]
                let net = (try? await c.get("NetWork.NetCommon", msg: 1042)) as? [String: Any] ?? [:]
                let dhcp = (try? await c.get("NetWork.NetDHCP", msg: 1042)) as? [[String: Any]] ?? []
                let rec = (try? await c.get("Record", msg: 1042)).flatMap { ($0 as? [[String: Any]])?.first ?? $0 as? [String: Any] } ?? [:]
                let nat = (try? await c.get("Status.NatInfo")) as? [String: Any] ?? [:]
                self.fill(sys: sys, time: time, storage: storage, gen: gen, net: net, dhcp: dhcp, rec: rec, nat: nat,
                          channels: c.channelCount)
                self.online = true
                self.updated = Date()
            } catch {
                self.online = false
                self.error = error.localizedDescription
            }
            self.loading = false
        }
    }

    // MARK: Formatting

    private static func str(_ v: Any?) -> String? {
        switch v {
        case let s as String: let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    private static func hex(_ v: Any?) -> UInt64? {
        if let n = v as? NSNumber { return n.uint64Value }
        guard let s = v as? String else { return nil }
        return UInt64(s.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16)
    }

    /// XMEye stores IPv4 addresses as little-endian hex, e.g. "0x5201A8C0" = 192.168.1.82.
    private static func ip(_ v: Any?) -> String? {
        guard let n = hex(v) else { return str(v) }
        return [n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, (n >> 24) & 0xFF].map(String.init).joined(separator: ".")
    }

    private static func bool(_ v: Any?) -> String? {
        if let b = v as? Bool { return b ? "Enabled" : "Disabled" }
        if let n = v as? NSNumber { return n.boolValue ? "Enabled" : "Disabled" }
        return str(v)
    }

    static func size(mb: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(mb * 1_048_576), countStyle: .binary)
    }

    private static func uptime(minutes: UInt64) -> String {
        let d = minutes / 1440, h = minutes / 60 % 24, m = minutes % 60
        return d > 0 ? "\(d)d \(h)h \(m)m" : "\(h)h \(m)m"
    }

    private func fill(sys: [String: Any], time: Date?, storage: [[String: Any]], gen: [String: Any],
                      net: [String: Any], dhcp: [[String: Any]], rec: [String: Any], nat: [String: Any], channels: Int?) {
        typealias S = DeviceModel
        func rows(_ pairs: [(String, String?)]) -> [InfoRow] { pairs.compactMap { p in p.1.map { InfoRow(label: p.0, value: $0) } } }
        let tz = AppModel.shared.nvrTimeZone
        let df = DateFormatter(); df.timeZone = tz; df.dateFormat = "dd-MM-yyyy HH:mm:ss"
        let host = AppModel.shared.host

        title = S.str(gen["MachineName"]) ?? S.str(sys["DeviceModel"]) ?? "NVR"
        system = rows([
            ("Model", S.str(sys["DeviceModel"]) ?? S.str(sys["HardWare"])),
            ("Software version", S.str(sys["SoftWareVersion"])),
            ("Build date & time", S.str(sys["BuildTime"])),
            ("Device date & time", time.map { df.string(from: $0) }),
            ("Uptime", S.hex(sys["DeviceRunTime"]).map { S.uptime(minutes: $0) }),
        ])
        device = rows([
            ("Device name", S.str(gen["MachineName"])),
            ("Device ID", "\(host):\(AppModel.shared.dvripPort)"),
            ("Cloud ID", S.str(sys["SerialNo"]) ?? S.str(nat["SerialNo"])),
            ("Hardware version", S.str(sys["HardWare"])),
            ("IP address", S.ip(net["HostIP"]) ?? host),
            ("Device type", "NVR"),
            ("Channels", (S.str(sys["VideoInChannel"]).flatMap(Int.init).map { $0 + (S.hex(sys["DigChannel"]).map(Int.init) ?? 0) } ?? channels).map(String.init)),
            ("Cloud status", S.str(nat["NatStatus"]).map { $0 == "Conneted" ? "Connected" : $0 }),
            ("Device status", "Online"),
        ])
        general = rows([
            ("HDD full", S.str(gen["OverWrite"]).map { $0 == "OverWrite" ? "Overwrite oldest" : $0 == "StopRecord" ? "Stop recording" : $0 }),
        ])
        network = rows([
            ("Host name", S.str(net["HostName"])),
            ("IP address", S.ip(net["HostIP"])),
            ("Subnet mask", S.ip(net["Submask"])),
            ("Gateway", S.ip(net["GateWay"])),
            ("MAC address", S.str(net["MAC"])),
            ("HTTP port", S.str(net["HttpPort"])),
            ("TCP port", S.str(net["TCPPort"])),
            ("UDP port", S.str(net["UDPPort"])),
            ("DHCP", dhcp.first.flatMap { S.bool($0["Enable"]) }),
        ])
        recording = rows([
            ("Pre-record", S.str(rec["PreRecord"]).map { "\($0) s" }),
            ("Redundancy", S.bool(rec["Redundancy"])),
            ("Packet length", S.str(rec["PacketLength"]).map { "\($0) min" }),
            ("Mode", S.str(rec["RecordMode"]).map { $0 == "ConfigRecord" ? "Scheduled" : $0 == "ManualRecord" ? "Manual" : $0 == "ClosedRecord" ? "Off" : $0 }),
        ])
        var list: [DiskInfo] = []
        for d in storage {
            for p in d["Partition"] as? [[String: Any]] ?? [] {
                guard let total = S.hex(p["TotalSpace"]), total > 0 else { continue }
                let status = S.hex(p["Status"]) ?? 0
                list.append(DiskInfo(id: list.count + 1, totalMB: Double(total), freeMB: Double(S.hex(p["RemainSpace"]) ?? 0),
                                     status: status == 0 ? "Normal" : "Error (\(status))",
                                     readWrite: (S.hex(p["DirverType"]) ?? 0) == 0,
                                     current: (p["IsCurrent"] as? Bool) ?? false))
            }
        }
        disks = list
        raw = sys.keys.sorted().compactMap { k in S.str(sys[k]).map { InfoRow(label: k, value: $0) } }
    }

    /// Plain-text summary for the clipboard.
    var report: String {
        var out = "\(title) — device information\n"
        for (name, rows) in [("System", system), ("Device", device), ("General", general), ("Network", network), ("Recording", recording)] where !rows.isEmpty {
            out += "\n\(name.uppercased())\n" + rows.map { "\($0.label): \($0.value)" }.joined(separator: "\n") + "\n"
        }
        for d in disks {
            out += "\nSTORAGE — partition \(d.id)\nTotal: \(Self.size(mb: d.totalMB))\nUsed: \(Self.size(mb: d.usedMB)) (\(Int(d.fraction * 100))%)\nFree: \(Self.size(mb: d.freeMB))\nStatus: \(d.status)\n"
        }
        return out
    }
}

// MARK: - View

struct DeviceView: View {
    @ObservedObject var dev = DeviceModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let e = dev.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), spacing: 16, alignment: .top)],
                          alignment: .leading, spacing: 16) {
                    InfoCard(title: "System", icon: "cpu", rows: dev.system)
                    InfoCard(title: "Device", icon: "server.rack", rows: dev.device)
                    InfoCard(title: "Network", icon: "network", rows: dev.network)
                    VStack(spacing: 16) {
                        InfoCard(title: "Recording", icon: "record.circle", rows: dev.recording + dev.general)
                        StorageCard(disks: dev.disks)
                    }
                }
                if !dev.raw.isEmpty {
                    DisclosureGroup("All system values") {
                        InfoCard(title: "SystemInfo", icon: "list.bullet", rows: dev.raw).padding(.top, 6)
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(20)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Device")
        .onAppear { if dev.updated == nil { dev.load() } }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 26))
                .frame(width: 52, height: 52)
                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(dev.title).font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Circle().fill(dev.online ? Color.green : Color.secondary).frame(width: 8, height: 8)
                    Text(dev.online ? "Online" : (dev.loading ? "Connecting…" : "Not connected"))
                    if let u = dev.updated {
                        Text("· updated \(u.formatted(date: .omitted, time: .standard))")
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if dev.loading { ProgressView().controlSize(.small) }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(dev.report, forType: .string)
                AppModel.shared.show(Toast(text: "Device information copied"))
            } label: { Label("Copy", systemImage: "doc.on.doc") }
            .disabled(!dev.online)
            Button { dev.load() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(dev.loading)
        }
    }
}

struct InfoCard: View {
    let title: String
    let icon: String
    let rows: [InfoRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title.uppercased(), systemImage: icon)
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("Not reported by this NVR").font(.callout).foregroundStyle(.tertiary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                    ForEach(rows) { r in
                        GridRow {
                            Text(r.label).foregroundStyle(.secondary)
                            Text(r.value).textSelection(.enabled).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct StorageCard: View {
    let disks: [DiskInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("STORAGE", systemImage: "internaldrive")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if disks.isEmpty {
                Text("No disk reported").font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(disks) { d in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Partition \(d.id)").font(.callout.weight(.medium))
                        Spacer()
                        Text("\(Int((d.fraction * 100).rounded()))% used").font(.callout).foregroundStyle(.secondary)
                    }
                    ProgressView(value: d.fraction)
                        .tint(d.fraction > 0.9 ? .orange : .accentColor)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                        GridRow { Text("Total").foregroundStyle(.secondary); Text(DeviceModel.size(mb: d.totalMB)) }
                        GridRow { Text("Used").foregroundStyle(.secondary); Text(DeviceModel.size(mb: d.usedMB)) }
                        GridRow { Text("Free").foregroundStyle(.secondary); Text(DeviceModel.size(mb: d.freeMB)) }
                        GridRow { Text("Type").foregroundStyle(.secondary); Text(d.readWrite ? "Read/Write" : "Read-only") }
                        GridRow { Text("Status").foregroundStyle(.secondary); Text(d.status + (d.current ? " (Active)" : "")) }
                    }
                    .font(.callout)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
