#if os(macOS)
import AppKit
import ObjectiveC.runtime

private enum VoiceLinkMenuImageRuntime {
    static var shouldShowImageKey: UInt8 = 0
    static var didInstallSwizzle = false
}

extension NSMenuItem {
    static func vl_installMainMenuImagePolicy() {
        guard !VoiceLinkMenuImageRuntime.didInstallSwizzle else { return }
        guard
            let originalMethod = class_getInstanceMethod(NSMenuItem.self, #selector(getter: NSMenuItem.image)),
            let swizzledMethod = class_getInstanceMethod(NSMenuItem.self, #selector(vl_swizzledImage))
        else {
            return
        }

        method_exchangeImplementations(originalMethod, swizzledMethod)
        VoiceLinkMenuImageRuntime.didInstallSwizzle = true
    }

    @objc dynamic private func vl_swizzledImage() -> NSImage? {
        if vl_shouldShowImage || vl_isToolbarItemRepresentation || !vl_isMainMenuItem || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return vl_swizzledImage()
        }
        return nil
    }

    private var vl_isToolbarItemRepresentation: Bool {
        menu == nil
    }

    private var vl_isMainMenuItem: Bool {
        menu?.supermenu == NSApplication.shared.mainMenu
    }

    var vl_shouldShowImage: Bool {
        get {
            (objc_getAssociatedObject(self, &VoiceLinkMenuImageRuntime.shouldShowImageKey) as? NSNumber)?.boolValue ?? false
        }
        set {
            objc_setAssociatedObject(
                self,
                &VoiceLinkMenuImageRuntime.shouldShowImageKey,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}
#endif
