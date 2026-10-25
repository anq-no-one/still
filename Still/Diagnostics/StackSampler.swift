import Darwin
import Foundation
import MachO

struct BinaryImage: Codable, Equatable, Sendable {
    var name: String
    var path: String
    var uuid: String
    var loadAddress: UInt
    var textSize: UInt
    var slide: Int

    func contains(_ address: UInt) -> Bool {
        address >= loadAddress && address < loadAddress + textSize
    }
}

/// Loaded binaries with their UUIDs and load addresses, which is what `atos`
/// needs to turn a raw address into a function and line with the build's dSYM.
enum BinaryImages {
    static func snapshot() -> [BinaryImage] {
        (0..<_dyld_image_count()).compactMap { index in
            guard let header = _dyld_get_image_header(index), let cName = _dyld_get_image_name(index) else { return nil }
            let path = String(cString: cName)
            let (uuid, textSize) = loadCommands(of: header)
            return BinaryImage(
                name: (path as NSString).lastPathComponent,
                path: path,
                uuid: uuid,
                loadAddress: UInt(bitPattern: header),
                textSize: textSize,
                slide: _dyld_get_image_vmaddr_slide(index)
            )
        }
    }

    static func image(containing address: UInt, in images: [BinaryImage]) -> BinaryImage? {
        images.first { $0.contains(address) }
    }

    private static func loadCommands(of header: UnsafePointer<mach_header>) -> (uuid: String, textSize: UInt) {
        guard header.pointee.magic == MH_MAGIC_64 else { return ("", 0) }
        var uuid = ""
        var textSize: UInt = 0
        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let command = cursor.load(as: load_command.self)
            if command.cmd == UInt32(LC_UUID) {
                let bytes = cursor.load(as: uuid_command.self).uuid
                uuid = withUnsafeBytes(of: bytes) { UUID(uuid: $0.load(as: uuid_t.self)).uuidString }
            } else if command.cmd == UInt32(LC_SEGMENT_64) {
                let segment = cursor.load(as: segment_command_64.self)
                let name = withUnsafeBytes(of: segment.segname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if name == "__TEXT" { textSize = UInt(segment.vmsize) }
            }
            cursor = cursor.advanced(by: Int(command.cmdsize))
        }
        return (uuid, textSize)
    }
}

struct Backtrace: Codable, Equatable, Sendable {
    var addresses: [UInt]

    var hex: String {
        addresses.map { "0x" + String($0, radix: 16) }.joined(separator: " ")
    }

    init(addresses: [UInt]) {
        self.addresses = addresses
    }

    init?(hex: String) {
        let addresses = hex.split(separator: " ").compactMap { UInt($0.dropFirst(2), radix: 16) }
        guard !addresses.isEmpty else { return nil }
        self.addresses = addresses
    }

    func symbolicated(with images: [BinaryImage]) -> [String] {
        addresses.enumerated().map { index, address in
            StackSampler.describe(address, index: index, images: images)
        }
    }
}

/// Reads another thread's call stack by pausing it for a few microseconds and
/// walking its frame-pointer chain. Nothing here allocates or takes a lock
/// while the thread is paused, because the paused thread may hold the
/// allocator's lock.
enum StackSampler {
    static let maximumFrames = 128

    static let addressMask: UInt = {
        var bits: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("machdep.virtual_address_size", &bits, &size, nil, 0) == 0, bits > 0, bits < 64 else {
            return (1 << 47) - 1
        }
        return (1 << UInt(bits)) - 1
    }()

    static func backtrace(of thread: thread_t) -> Backtrace? {
        guard thread != pthread_mach_thread_np(pthread_self()) else { return nil }
        let frames = UnsafeMutablePointer<UInt>.allocate(capacity: maximumFrames)
        defer { frames.deallocate() }
        let mask = addressMask

        guard thread_suspend(thread) == KERN_SUCCESS else { return nil }
        let count = walk(thread, into: frames, mask: mask)
        thread_resume(thread)

        guard count > 0 else { return nil }
        return Backtrace(addresses: Array(UnsafeBufferPointer(start: frames, count: count)))
    }

    static func backtraceOfMain() -> Backtrace? {
        ProcessProbe.mainThread.flatMap(backtrace(of:))
    }

    static func walk(_ thread: thread_t, into frames: UnsafeMutablePointer<UInt>, mask: UInt) -> Int {
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return walkFrames(pc: UInt(state.__pc), lr: UInt(state.__lr), fp: UInt(state.__fp), into: frames, mask: mask)
        #else
        return 0
        #endif
    }

    static func walkFrames(pc: UInt, lr: UInt, fp: UInt, into frames: UnsafeMutablePointer<UInt>, mask: UInt) -> Int {
        var count = 0
        frames[count] = pc & mask
        count += 1
        let returnAddress = lr & mask
        if returnAddress != 0 {
            frames[count] = returnAddress
            count += 1
        }
        var framePointer = fp & mask
        var record: (UInt, UInt) = (0, 0)
        while count < maximumFrames, framePointer != 0, framePointer & 0x7 == 0 {
            var copied: vm_size_t = 0
            let read = withUnsafeMutablePointer(to: &record) { pointer in
                vm_read_overwrite(
                    mach_task_self_,
                    vm_address_t(framePointer),
                    vm_size_t(MemoryLayout<(UInt, UInt)>.size),
                    vm_address_t(UInt(bitPattern: pointer)),
                    &copied
                )
            }
            guard read == KERN_SUCCESS else { break }
            let next = record.0 & mask
            let caller = record.1 & mask
            guard caller != 0 else { break }
            if !(count == 2 && caller == frames[1]) {
                frames[count] = caller
                count += 1
            }
            guard next > framePointer else { break }
            framePointer = next
        }
        return count
    }

    static func describe(_ address: UInt, index: Int, images: [BinaryImage]) -> String {
        let image = BinaryImages.image(containing: address, in: images)
        var info = Dl_info()
        var symbol = ""
        if let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0, let name = info.dli_sname {
            let offset = address - UInt(bitPattern: info.dli_saddr)
            symbol = " \(String(cString: name)) + \(offset)"
        }
        let imageName = image?.name ?? "???"
        let load = image.map { " (load 0x\(String($0.loadAddress, radix: 16)))" } ?? ""
        return String(format: "%3d ", index) + imageName.padding(toLength: 28, withPad: " ", startingAt: 0)
            + " 0x" + String(address, radix: 16) + load + symbol
    }

    /// The frames several samples of a hang share, heaviest first, so a
    /// stack that kept main busy the whole time stands out from noise.
    static func profile(_ samples: [Backtrace], limit: Int = 16) -> [(address: UInt, count: Int)] {
        var counts: [UInt: Int] = [:]
        for sample in samples {
            for address in Set(sample.addresses) {
                counts[address, default: 0] += 1
            }
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(limit).map { ($0.key, $0.value) }
    }

    static func heaviest(_ samples: [Backtrace]) -> Backtrace? {
        let counts = profile(samples, limit: Int.max).reduce(into: [UInt: Int]()) { $0[$1.address] = $1.count }
        return samples.max { lhs, rhs in
            let left = lhs.addresses.prefix(8).reduce(0) { $0 + (counts[$1] ?? 0) }
            let right = rhs.addresses.prefix(8).reduce(0) { $0 + (counts[$1] ?? 0) }
            return left < right
        }
    }

    /// Every thread's name, CPU and stack at this moment.
    static func allThreadsReport() -> String {
        let images = BinaryImages.snapshot()
        let threads = ProcessProbe.threads { backtrace(of: $0) }
        var lines = ["Threads at \(Date.now.formatted(.iso8601)) — \(threads.count) threads", ""]
        for (thread, backtrace) in threads.sorted(by: { ($0.usage.isMain ? 1 : 0, $0.usage.cpuPercent) > ($1.usage.isMain ? 1 : 0, $1.usage.cpuPercent) }) {
            lines.append(
                "Thread \(thread.label) tid=\(thread.id) cpu=\(String(format: "%.1f", thread.cpuPercent))% user=\(String(format: "%.2f", thread.userS))s sys=\(String(format: "%.2f", thread.systemS))s\(thread.isIdle ? " idle" : "")"
            )
            if let backtrace {
                lines.append(contentsOf: backtrace.symbolicated(with: images))
            } else {
                lines.append("    (this thread: the one taking the snapshot)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
