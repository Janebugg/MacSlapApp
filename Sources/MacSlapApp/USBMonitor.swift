import Foundation
import IOKit
import IOKit.usb

/// Monitors USB/Thunderbolt device plug/unplug via IOKit publish/terminated
/// notifications for IOUSBHostDevice.
///
/// Some devices (docks, monitors, phones) drop off the bus and re-enumerate
/// every few seconds while plugged in. A device that reappears shortly after
/// it left, or leaves shortly after it appeared, is treated as that flapping
/// rather than as a real plug or unplug.
@MainActor
final class USBMonitor {
    private struct Device {
        let key: String
        let name: String
    }

    private static let flapWindow: TimeInterval = 15
    /// A dock publishes several devices at once; that is still one plug.
    private static let debounceInterval: TimeInterval = 2

    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var publishedAt: [String: Date] = [:]
    private var removedAt: [String: Date] = [:]
    private var lastPlug: Date = .distantPast
    private var lastUnplug: Date = .distantPast

    var onPlugged: (() -> Void)?
    var onUnplugged: (() -> Void)?

    func start() {
        guard notifyPort == nil else { return }
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(),
                           .defaultMode)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        for (notification, callback) in [
            (kIOPublishNotification, Self.publishCallback),
            (kIOTerminatedNotification, Self.terminateCallback),
        ] {
            guard let matching = IOServiceMatching("IOUSBHostDevice") else { continue }
            var iter: io_iterator_t = 0
            guard IOServiceAddMatchingNotification(notifyPort, notification, matching, callback,
                                                   selfPtr, &iter) == KERN_SUCCESS else { continue }
            // Drain the initial matches so devices already present don't fire.
            _ = Self.devices(in: iter)
            iterators.append(iter)
        }
        log("USB monitor started")
    }

    func stop() {
        guard let port = notifyPort else { return }
        for iter in iterators { IOObjectRelease(iter) }
        iterators.removeAll()
        IONotificationPortDestroy(port)
        notifyPort = nil
        log("USB monitor stopped")
    }

    // Delivered on the main run loop (source added in start()).
    private static let publishCallback: IOServiceMatchingCallback = { refcon, iterator in
        guard let refcon else { return }
        let found = devices(in: iterator)
        let monitor = Unmanaged<USBMonitor>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { monitor.published(found) }
    }

    private static let terminateCallback: IOServiceMatchingCallback = { refcon, iterator in
        guard let refcon else { return }
        let found = devices(in: iterator)
        let monitor = Unmanaged<USBMonitor>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { monitor.terminated(found) }
    }

    private func published(_ devices: [Device]) {
        let now = Date()
        var fresh: [Device] = []
        for device in devices {
            publishedAt[device.key] = now
            if let removed = removedAt[device.key], now.timeIntervalSince(removed) < Self.flapWindow {
                continue
            }
            fresh.append(device)
        }
        guard !fresh.isEmpty, now.timeIntervalSince(lastPlug) >= Self.debounceInterval else { return }
        lastPlug = now
        log("USB plugged in: \(fresh.map(\.name).joined(separator: ", "))")
        onPlugged?()
    }

    private func terminated(_ devices: [Device]) {
        let now = Date()
        var gone: [Device] = []
        for device in devices {
            removedAt[device.key] = now
            if let published = publishedAt[device.key], now.timeIntervalSince(published) < Self.flapWindow {
                continue
            }
            gone.append(device)
        }
        guard !gone.isEmpty, now.timeIntervalSince(lastUnplug) >= Self.debounceInterval else { return }
        lastUnplug = now
        log("USB unplugged: \(gone.map(\.name).joined(separator: ", "))")
        onUnplugged?()
    }

    /// Consumes the iterator. A terminated device's properties are still readable here.
    nonisolated private static func devices(in iterator: io_iterator_t) -> [Device] {
        var result: [Device] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue()
            }
            let location = (property("locationID") as? NSNumber)?.stringValue ?? "?"
            let vendor = (property("idVendor") as? NSNumber)?.stringValue ?? "?"
            let product = (property("idProduct") as? NSNumber)?.stringValue ?? "?"
            let name = property("USB Product Name") as? String ?? "USB device"
            result.append(Device(key: "\(location):\(vendor):\(product)", name: name))
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return result
    }
}
