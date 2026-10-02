import SwiftUI
import UIKit
import Combine

enum CameraQuickAction: String, CaseIterable {
    case library
    case collections
    case templates

    var title: String {
        switch self {
        case .library: "Library"
        case .collections: "Collections"
        case .templates: "Templates"
        }
    }

    var symbol: String {
        switch self {
        case .library: "photo.on.rectangle.fill"
        case .collections: "square.stack.fill"
        case .templates: "doc.text"
        }
    }

    var shortcutType: String { "workcamera.open.\(rawValue)" }

    init?(shortcutItem: UIApplicationShortcutItem) {
        guard let action = Self.allCases.first(where: { $0.shortcutType == shortcutItem.type }) else { return nil }
        self = action
    }
}

struct CameraQuickActionRequest: Equatable {
    let id = UUID()
    let action: CameraQuickAction
}

@MainActor
final class CameraQuickActionRouter: ObservableObject {
    static let shared = CameraQuickActionRouter()
    @Published private(set) var requests: [String: CameraQuickActionRequest] = [:]

    func enqueue(_ action: CameraQuickAction, for session: UISceneSession) {
        requests[session.persistentIdentifier] = CameraQuickActionRequest(action: action)
    }

    func takeRequest(for session: UISceneSession) -> CameraQuickActionRequest? {
        let sceneID = session.persistentIdentifier
        guard requests[sceneID] != nil else { return nil }
        return requests.removeValue(forKey: sceneID)
    }
}

@main struct MyApp: App {
    @UIApplicationDelegateAdaptor(CameraAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

@MainActor
final class CameraAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.shortcutItems = CameraQuickAction.allCases.reversed().map { action in
            UIApplicationShortcutItem(
                type: action.shortcutType,
                localizedTitle: action.title,
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: action.symbol),
                userInfo: nil
            )
        }
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let item = options.shortcutItem, let action = CameraQuickAction(shortcutItem: item) {
            CameraQuickActionRouter.shared.enqueue(action, for: connectingSceneSession)
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = CameraSceneDelegate.self
        return configuration
    }
}

@MainActor
final class CameraSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard let action = CameraQuickAction(shortcutItem: shortcutItem) else {
            completionHandler(false)
            return
        }
        CameraQuickActionRouter.shared.enqueue(action, for: windowScene.session)
        completionHandler(true)
    }

    func supportedInterfaceOrientations(for windowScene: UIWindowScene) -> UIInterfaceOrientationMask {
        CameraOrientationPolicy.supportedOrientations(for: windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        CameraOrientationPolicy.removeScene(scene)
    }
}

// This reader remains mounted while either the camera or the library is visible.
// Quick-action routing must not depend on creating a camera preview first.
private final class CameraWindowSceneView: UIView {
    var onSceneChange: ((UIWindowScene) -> Void)?
    private weak var reportedScene: UIWindowScene?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportSceneIfNeeded()
    }

    func reportSceneIfNeeded() {
        guard let scene = window?.windowScene, reportedScene !== scene else { return }
        reportedScene = scene
        // Defer SwiftUI state changes until the UIKit view update has finished.
        DispatchQueue.main.async { [weak self, weak scene] in
            guard let scene, self?.window?.windowScene === scene else { return }
            self?.onSceneChange?(scene)
        }
    }
}

struct CameraWindowSceneReader: UIViewRepresentable {
    let onSceneChange: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = CameraWindowSceneView()
        view.isUserInteractionEnabled = false
        view.onSceneChange = onSceneChange
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let view = uiView as? CameraWindowSceneView else { return }
        view.onSceneChange = onSceneChange
        view.reportSceneIfNeeded()
    }
}

@MainActor
enum CameraOrientationPolicy {
    private static var librarySceneIDs: Set<String> = []

    static func supportedOrientations(for scene: UIWindowScene) -> UIInterfaceOrientationMask {
        librarySceneIDs.contains(scene.session.persistentIdentifier) ? .all : .portrait
    }

    static func setLibraryPresented(
        _ presented: Bool,
        in scene: UIWindowScene,
        onError: @escaping (Error) -> Void
    ) {
        let sceneID = scene.session.persistentIdentifier
        if presented { librarySceneIDs.insert(sceneID) }
        else { librarySceneIDs.remove(sceneID) }

        for window in scene.windows {
            if let root = window.rootViewController { refreshOrientationSupport(in: root) }
        }

        // The library resumes normal scene rotation; the camera uses portrait coordinates.
        let requestedOrientation: UIInterfaceOrientationMask = presented ? .all : .portrait
        let currentOrientation: UIInterfaceOrientationMask = switch scene.effectiveGeometry.interfaceOrientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: []
        }
        guard currentOrientation.isEmpty || requestedOrientation.intersection(currentOrientation).isEmpty else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: requestedOrientation), errorHandler: onError)
    }

    static func removeScene(_ scene: UIScene) {
        librarySceneIDs.remove(scene.session.persistentIdentifier)
    }

    private static func refreshOrientationSupport(in controller: UIViewController) {
        controller.setNeedsUpdateOfSupportedInterfaceOrientations()
        for child in controller.children { refreshOrientationSupport(in: child) }
        if let presented = controller.presentedViewController { refreshOrientationSupport(in: presented) }
    }
}
