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


// Each scene resolves its destination before ContentView is created.
@MainActor
final class CameraSceneNavigation: ObservableObject {
    @Published private(set) var libraryVisible = false
    @Published private(set) var isReadyToDisplay: Bool
    @Published private(set) var quickAction: CameraQuickActionRequest?
    @Published private(set) var scenePhase: ScenePhase = .inactive
    @Published var errorMessage: String?

    private struct OrientationTransition {
        let id = UUID()
        let opensLibrary: Bool
        var orientation: UIInterfaceOrientation
        let action: CameraQuickActionRequest?
    }

    private weak var scene: UIWindowScene?
    private weak var rootController: UIViewController?
    private var pendingTransition: OrientationTransition?
    private var needsOrientationUpdate = true
    private var transitionTimeout: Task<Void, Never>?
    private var deviceOrientationSubscription: AnyCancellable?
    private var isGeneratingOrientationNotifications = false
    private var isDisconnected = false

    init(initialAction: CameraQuickAction?) {
        isReadyToDisplay = initialAction == nil
        if let initialAction {
            // Install the entry policy before SwiftUI constructs the destination.
            pendingTransition = OrientationTransition(
                opensLibrary: true, orientation: .unknown,
                action: CameraQuickActionRequest(action: initialAction)
            )
        }
    }

    func attach(to scene: UIWindowScene, rootController: UIViewController? = nil) {
        guard !isDisconnected else { return }
        self.scene = scene
        if !isGeneratingOrientationNotifications {
            isGeneratingOrientationNotifications = true
            deviceOrientationSubscription = NotificationCenter.default
                .publisher(for: UIDevice.orientationDidChangeNotification)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, !self.isDisconnected else { return }
                        self.resolveUnspecifiedOrientation()
                        self.updateOrientationPolicy()
                        self.finishTransitionIfReady()
                        self.requestOrientationUpdateIfNeeded()
                    }
                }
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
        let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        let controller = rootController ?? window?.rootViewController
        if self.rootController !== controller {
            self.rootController = controller
            needsOrientationUpdate = true
        }
        resolveUnspecifiedOrientation()
        updateOrientationPolicy()
        finishTransitionIfReady()
        requestOrientationUpdateIfNeeded()
    }

    func setScenePhase(_ phase: ScenePhase) {
        guard !isDisconnected else { return }
        scenePhase = phase
        if phase == .active {
            resolveUnspecifiedOrientation()
            updateOrientationPolicy()
            finishTransitionIfReady()
            requestOrientationUpdateIfNeeded()
        } else {
            transitionTimeout?.cancel()
            transitionTimeout = nil
            if pendingTransition != nil { needsOrientationUpdate = true }
        }
    }

    func openLibrary(action: CameraQuickAction? = nil) {
        guard !isDisconnected else { return }
        beginTransition(opensLibrary: true,
                        orientation: scene.map { libraryEntryOrientation(in: $0) } ?? .unknown,
                        action: action.map { CameraQuickActionRequest(action: $0) })
    }

    func returnToCamera() {
        guard !isDisconnected, libraryVisible || pendingTransition != nil else { return }
        beginTransition(opensLibrary: false, orientation: .portrait, action: nil)
    }

    private func beginTransition(opensLibrary: Bool, orientation: UIInterfaceOrientation,
                                 action: CameraQuickActionRequest?) {
        transitionTimeout?.cancel()
        transitionTimeout = nil
        errorMessage = nil
        pendingTransition = OrientationTransition(opensLibrary: opensLibrary,
                                                  orientation: orientation, action: action)
        needsOrientationUpdate = true
        updateOrientationPolicy()
        finishTransitionIfReady()
        requestOrientationUpdateIfNeeded()
    }

    private func libraryEntryOrientation(in scene: UIWindowScene) -> UIInterfaceOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        case .portrait: return .portrait
        case .unknown: return .unknown
        default:
            // Face-up/down readings retain a valid scene orientation.
            let current = scene.effectiveGeometry.interfaceOrientation
            switch current {
            case .portrait, .landscapeLeft, .landscapeRight: return current
            default: return .unknown
            }
        }
    }

    private func resolveUnspecifiedOrientation() {
        // Cold shortcuts have no camera preview to generate device orientation
        // readings. Wait for a real reading after activation/window attachment.
        guard pendingTransition?.orientation == .unknown, scenePhase == .active,
              rootController != nil, let scene else { return }
        let orientation = libraryEntryOrientation(in: scene)
        guard orientation != .unknown else { return }
        pendingTransition?.orientation = orientation
        needsOrientationUpdate = true
    }

    private func updateOrientationPolicy() {
        guard let scene else { return }
        let mask: UIInterfaceOrientationMask
        if let pendingTransition {
            switch pendingTransition.orientation {
            case .landscapeLeft: mask = .landscapeLeft
            case .landscapeRight: mask = .landscapeRight
            case .unknown:
                // Existing camera content stays portrait until a real target is
                // known. Cold entry lets UIKit establish the initial scene.
                mask = !isReadyToDisplay || libraryVisible ? .allButUpsideDown : .portrait
            default: mask = .portrait
            }
        } else {
            mask = libraryVisible ? .allButUpsideDown : .portrait
        }
        CameraOrientationPolicy.setSupportedOrientations(mask, in: scene)
    }

    private func requestOrientationUpdateIfNeeded() {
        guard needsOrientationUpdate, scenePhase == .active, let rootController else { return }
        needsOrientationUpdate = false
        // UIKit explicitly supports a nonanimated orientation update through this
        // API. Geometry requests do not provide that same animation guarantee.
        UIView.performWithoutAnimation {
            rootController.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        finishTransitionIfReady()
        guard let pendingTransition else { return }
        let requestID = pendingTransition.id
        transitionTimeout?.cancel()
        transitionTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            guard let self, !Task.isCancelled,
                  self.pendingTransition?.id == requestID, self.scenePhase == .active else { return }
            self.finishTransitionIfReady()
            guard self.pendingTransition?.id == requestID else { return }
            // A timeout reports a rejected/unfulfilled update; it never reveals
            // the requested page using the wrong orientation as a fallback.
            self.pendingTransition = nil
            self.transitionTimeout = nil
            self.isReadyToDisplay = true
            self.updateOrientationPolicy()
            self.needsOrientationUpdate = true
            self.requestOrientationUpdateIfNeeded()
            self.errorMessage = "Could not change the screen orientation. Please try again."
        }
    }

    func finishTransitionIfReady() {
        guard let transition = pendingTransition, transition.orientation != .unknown, let scene,
              scene.effectiveGeometry.interfaceOrientation == transition.orientation,
              let window = scene.windows.first(where: \.isKeyWindow),
              window.bounds.width > 0, window.bounds.height > 0 else { return }
        // Geometry can be reported before the window's layout has caught up.
        let size = window.bounds.size
        guard transition.orientation.isLandscape ? size.width > size.height : size.height >= size.width else { return }
        transitionTimeout?.cancel()
        transitionTimeout = nil
        pendingTransition = nil
        quickAction = transition.action
        libraryVisible = transition.opensLibrary
        isReadyToDisplay = true
        updateOrientationPolicy()
        needsOrientationUpdate = true
        requestOrientationUpdateIfNeeded()
    }

    func disconnect() {
        isDisconnected = true
        transitionTimeout?.cancel()
        transitionTimeout = nil
        deviceOrientationSubscription = nil
        if isGeneratingOrientationNotifications {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            isGeneratingOrientationNotifications = false
        }
        pendingTransition = nil
        scenePhase = .background
        scene = nil
        rootController = nil
    }
}

// SwiftUI owns the app graph and windows; the delegate supplies scene routing.
@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor(CameraAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            CameraSceneRoot()
        }
    }
}

private struct CameraSceneRoot: View {
    @EnvironmentObject private var sceneDelegate: CameraSceneDelegate

    var body: some View {
        if let navigation = sceneDelegate.navigation {
            CameraNavigationRoot(navigation: navigation)
        }
        // No camera or Library is constructed until the scene resolves its entry.
    }
}

private struct CameraNavigationRoot: View {
    @ObservedObject var navigation: CameraSceneNavigation

    var body: some View {
        ZStack {
            if navigation.isReadyToDisplay {
                ContentView(navigation: navigation)
                    .id(ObjectIdentifier(navigation))
            }
        }
        .background {
            // Resolve cold shortcut geometry before constructing its first
            // page; this reader remains mounted throughout route changes.
            CameraWindowSceneReader { scene in
                navigation.attach(to: scene)
            }
            .frame(width: 0, height: 0)
        }
    }
}

@MainActor
final class CameraAppDelegate: NSObject, UIApplicationDelegate, ObservableObject {
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
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = CameraSceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        guard let scene = window?.windowScene else { return .allButUpsideDown }
        return CameraOrientationPolicy.supportedOrientations(for: scene)
    }
}

@MainActor
final class CameraSceneDelegate: NSObject, UIWindowSceneDelegate, ObservableObject {
    @Published private(set) var navigation: CameraSceneNavigation?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let initialAction = connectionOptions.shortcutItem.flatMap { CameraQuickAction(shortcutItem: $0) }
        let navigation = CameraSceneNavigation(initialAction: initialAction)
        navigation.attach(to: windowScene)
        self.navigation = navigation
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard let navigation, let action = CameraQuickAction(shortcutItem: shortcutItem) else {
            completionHandler(false)
            return
        }
        navigation.openLibrary(action: action)
        completionHandler(true)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        navigation?.setScenePhase(.active)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        navigation?.setScenePhase(.inactive)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        navigation?.setScenePhase(.inactive)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        navigation?.setScenePhase(.background)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func windowScene(_ windowScene: UIWindowScene, didUpdateEffectiveGeometry previousEffectiveGeometry: UIWindowScene.Geometry) {
        navigation?.finishTransitionIfReady()
        NotificationCenter.default.post(name: CameraOrientationPolicy.geometryDidChange, object: windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        navigation?.disconnect()
        CameraOrientationPolicy.removeScene(scene)
        navigation = nil
    }
}

// This reader remains mounted while either the camera or the library is visible.
// Camera layout must not depend on creating a camera preview first.
private final class CameraWindowSceneView: UIView {
    var onSceneChange: ((UIWindowScene) -> Void)?
    private weak var reportedScene: UIWindowScene?
    private var reportedOrientation: UIInterfaceOrientation?
    private var reportedInsets: UIEdgeInsets?
    private var reportedSize: CGSize?

    override init(frame: CGRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneGeometryDidChange(_:)),
            name: CameraOrientationPolicy.geometryDidChange, object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func sceneGeometryDidChange(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene,
              window?.windowScene === scene else { return }
        reportSceneIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportSceneIfNeeded()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        reportSceneIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportSceneIfNeeded()
    }

    func reportSceneIfNeeded() {
        guard let window, let scene = window.windowScene else { return }
        let orientation = scene.effectiveGeometry.interfaceOrientation
        let insets = window.safeAreaInsets
        let size = window.bounds.size
        guard reportedScene !== scene || reportedOrientation != orientation || reportedInsets != insets || reportedSize != size else { return }
        reportedScene = scene
        reportedOrientation = orientation
        reportedInsets = insets
        reportedSize = size
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

// The camera scene is portrait-only. Keep the controls and preview in those
// fixed coordinates; handset rotation changes labels and capture orientation only.
private final class FixedPortraitCameraController: UIViewController {
    private let hosting = UIHostingController(rootView: AnyView(EmptyView()))
    private var portraitSize: CGSize = .zero

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        hosting.safeAreaRegions = []
        hosting.view.backgroundColor = .black
        hosting.view.autoresizingMask = []
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        hosting.view.bounds = CGRect(origin: .zero, size: portraitSize)
        hosting.view.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    }

    override func size(forChildContentContainer container: UIContentContainer, withParentContainerSize parentSize: CGSize) -> CGSize {
        if (container as AnyObject) === hosting { return portraitSize }
        return super.size(forChildContentContainer: container, withParentContainerSize: parentSize)
    }

    func updateContent(_ content: AnyView, portraitSize: CGSize) {
        self.portraitSize = portraitSize
        hosting.rootView = content
        viewIfLoaded?.setNeedsLayout()
    }
}

struct FixedPortraitCameraCanvas<Content: View>: UIViewControllerRepresentable {
    let portraitSize: CGSize
    let content: Content

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = FixedPortraitCameraController()
        controller.updateContent(AnyView(content), portraitSize: portraitSize)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        (uiViewController as? FixedPortraitCameraController)?.updateContent(AnyView(content), portraitSize: portraitSize)
    }
}

@MainActor
enum CameraOrientationPolicy {
    static let geometryDidChange = Notification.Name("WorkCameraSceneGeometryDidChange")
    private static var sceneMasks: [String: UIInterfaceOrientationMask] = [:]

    static func supportedOrientations(for scene: UIWindowScene) -> UIInterfaceOrientationMask {
        sceneMasks[scene.session.persistentIdentifier] ?? .portrait
    }

    static func setSupportedOrientations(_ mask: UIInterfaceOrientationMask, in scene: UIWindowScene) {
        sceneMasks[scene.session.persistentIdentifier] = mask
    }

    static func removeScene(_ scene: UIScene) {
        sceneMasks.removeValue(forKey: scene.session.persistentIdentifier)
    }
}
