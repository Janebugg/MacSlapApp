import Foundation
import IOKit
import IOKit.ps

/// Reports lid open/close and charger plug/unplug, which shake the chassis
/// hard enough to look like a slap to the accelerometer, and tells apart a
/// lid opening so it can get a sound of its own.
@MainActor
final class ChassisMonitor {
    /// kIOPMMessageClamshellStateChange; the C macro isn't imported into Swift.
    private static let clamshellStateChange: natural_t = 0xE003_4100

    private var notifyPort: IONotificationPortRef?
    private var rootDomain: io_service_t = 0
    private var lidClosed = false
    private var clamshellNotifier: io_object_t = 0
    private var powerSource: CFRunLoopSource?

    var onEvent: ((String) -> Void)?
    var onLidOpened: (() -> Void)?

    func start() {
        guard notifyPort == nil else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        if let notifyPort {
            CFRunLoopAddSource(CFRunLoopGetMain(),
                               IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(),
                               .defaultMode)
            rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
            lidClosed = readLidClosed()
            if rootDomain != 0 {
                IOServiceAddInterestNotification(
                    notifyPort, rootDomain, kIOGeneralInterest,
                    { refcon, _, messageType, _ in
                        guard messageType == ChassisMonitor.clamshellStateChange, let refcon else { return }
                        let monitor = Unmanaged<ChassisMonitor>.fromOpaque(refcon).takeUnretainedValue()
                        MainActor.assumeIsolated { monitor.lidStateChanged() }
                    },
                    selfPtr, &clamshellNotifier
                )
            }
        }

        if let source = IOPSNotificationCreateRunLoopSource({ refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<ChassisMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.onEvent?("power source") }
        }, selfPtr)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        log("Chassis monitor started (lid + power source)")
    }

    func stop() {
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        powerSource = nil
        if clamshellNotifier != 0 { IOObjectRelease(clamshellNotifier); clamshellNotifier = 0 }
        if rootDomain != 0 { IOObjectRelease(rootDomain); rootDomain = 0 }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        notifyPort = nil
    }

    private func lidStateChanged() {
        onEvent?("lid")
        let closed = readLidClosed()
        // The message can repeat without a state change; only a real close → open counts.
        if lidClosed && !closed { onLidOpened?() }
        lidClosed = closed
    }

    private func readLidClosed() -> Bool {
        guard rootDomain != 0,
              let value = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return false }
        return (value as? Bool) ?? false
    }
}
