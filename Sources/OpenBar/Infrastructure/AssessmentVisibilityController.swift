import Foundation
import ObjectiveC

/// macOS 27 MenuBarAgent assessment owned by the main app, matching the
/// working Open Notch implementation. Keeping the assertion here means the
/// app's own native NSStatusItem stays in the same ordinary status-item domain
/// as every other product.
final class AssessmentVisibilityController {
    enum Result { case applied, unavailable, failed(String) }

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
    private var assertion: NSObject?
    private var generation: UInt64 = 0
    private let lock = NSLock()

    deinit { invalidate() }

    func apply(
        allowedSystemItems: Set<Int>,
        allowedBundleIdentifiers: Set<String>,
        completion: @escaping (Result) -> Void
    ) {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
              dlopen(Self.frameworkPath, RTLD_NOW) != nil,
              let configurationClass = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type,
              let assertionClass = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type
        else { completion(.unavailable); return }

        guard let configuration = class_createInstance(configurationClass, 0) as AnyObject? else {
            completion(.failed("configuration allocation failed")); return
        }
        let configSelector = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
        typealias ConfigIMP = @convention(c) (AnyObject, Selector, NSArray, NSArray) -> AnyObject?
        guard let configMethod = class_getInstanceMethod(configurationClass, configSelector) else {
            completion(.unavailable); return
        }
        let configured = unsafeBitCast(method_getImplementation(configMethod), to: ConfigIMP.self)(
            configuration,
            configSelector,
            allowedSystemItems.sorted().map { NSNumber(value: $0) } as NSArray,
            allowedBundleIdentifiers.sorted() as NSArray
        )
        guard let configured else { completion(.failed("configuration rejected")); return }

        let candidate = assertionClass.init()
        lock.lock()
        generation &+= 1
        let requestGeneration = generation
        lock.unlock()

        let activateSelector = NSSelectorFromString("activateWithConfiguration:completionHandler:")
        typealias CompletionBlock = @convention(block) (NSError?) -> Void
        typealias ActivateIMP = @convention(c) (AnyObject, Selector, AnyObject, CompletionBlock) -> Void
        guard let activateMethod = class_getInstanceMethod(assertionClass, activateSelector) else {
            completion(.unavailable); return
        }
        let activate = unsafeBitCast(method_getImplementation(activateMethod), to: ActivateIMP.self)
        let callback: CompletionBlock = { [weak self] error in
            guard let self else { return }
            self.lock.lock()
            let isCurrent = self.generation == requestGeneration
            if !isCurrent {
                self.lock.unlock()
                Self.invalidate(candidate)
                return
            }
            if let error {
                self.lock.unlock()
                completion(.failed(error.localizedDescription))
                return
            }
            let previous = self.assertion
            self.assertion = candidate
            self.lock.unlock()
            Self.invalidate(previous)
            completion(.applied)
        }
        activate(candidate, activateSelector, configured, callback)
    }

    func stop() { invalidate() }

    private func invalidate() {
        lock.lock()
        generation &+= 1
        let current = assertion
        assertion = nil
        lock.unlock()
        Self.invalidate(current)
    }

    private static func invalidate(_ object: NSObject?) {
        guard let object else { return }
        let selector = NSSelectorFromString("invalidate")
        guard let method = class_getInstanceMethod(type(of: object), selector) else { return }
        typealias InvalidateIMP = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(method_getImplementation(method), to: InvalidateIMP.self)(object, selector)
    }
}
