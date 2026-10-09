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
    @Published private(set) var libraryVisible: Bool
    @Published private(set) var quickAction: CameraQuickActionRequest?
    @Published private(set) var scenePhase: ScenePhase = .inactive
    @Published var errorMessage: String?
    private weak var scene: UIWindowScene?
    private weak var rootController: UIViewController?
    private var returnRequestID: UUID?
    private var needsLibraryEntryOrientation: Bool
    private var isDisconnected = false

    init(initialAction: CameraQuickAction?) {
        libraryVisible = initialAction != nil
        needsLibraryEntryOrientation = initialAction != nil
        quickAction = initialAction.map { CameraQuickActionRequest(action: $0) }
    }

    func attach(to scene: UIWindowScene, rootController: UIViewController? = nil) {
        guard !isDisconnected else { return }
        self.scene = scene
        self.rootController = rootController ?? scene.windows.first(where: \.isKeyWindow)?.rootViewController
        CameraOrientationPolicy.setLibraryVisible(libraryVisible && returnRequestID == nil, in: scene)
        self.rootController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        updateLibraryEntryOrientation()
    }

    func setScenePhase(_ phase: ScenePhase) {
        scenePhase = phase
        if phase == .active {
            finishReturnIfPortrait()
            updateLibraryEntryOrientation()
        }
    }

    func openLibrary(action: CameraQuickAction? = nil) {
        // A new shortcut cancels any pending return and replaces its destination.
        returnRequestID = nil
        errorMessage = nil
        quickAction = action.map { CameraQuickActionRequest(action: $0) }
        if let scene { CameraOrientationPolicy.setLibraryVisible(true, in: scene) }
        libraryVisible = true
        needsLibraryEntryOrientation = true
        rootController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        updateLibraryEntryOrientation()
    }

    private func updateLibraryEntryOrientation() {
        guard needsLibraryEntryOrientation, libraryVisible,
              scenePhase == .active, let scene, rootController != nil else { return }
        needsLibraryEntryOrientation = false
        let orientation: UIInterfaceOrientationMask
        switch UIDevice.current.orientation {
        case .landscapeLeft: orientation = .landscapeRight
        case .landscapeRight: orientation = .landscapeLeft
        default: orientation = .portrait
        }
        // Enter using the handset orientation, then allow normal Library rotation.
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
    }

    func returnToCamera() {
        guard libraryVisible, returnRequestID == nil, let scene else { return }
        let requestID = UUID()
        returnRequestID = requestID
        needsLibraryEntryOrientation = false
        CameraOrientationPolicy.setLibraryVisible(false, in: scene)
        rootController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if scene.effectiveGeometry.interfaceOrientation == .portrait {
            finishReturnIfPortrait()
        } else {
            // Library remains the actual root content until geometry is portrait.
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, self.returnRequestID == requestID else { return }
                    self.returnRequestID = nil
                    CameraOrientationPolicy.setLibraryVisible(true, in: scene)
                    self.rootController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                    self.errorMessage = "Could not return to the camera: \(error.localizedDescription)"
                }
            }
        }
    }

    func finishReturnIfPortrait() {
        guard returnRequestID != nil,
              scene?.effectiveGeometry.interfaceOrientation == .portrait else { return }
        returnRequestID = nil
        quickAction = nil
        libraryVisible = false
    }

    func disconnect() {
        isDisconnected = true
        returnRequestID = nil
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
            ContentView(navigation: navigation)
                .id(ObjectIdentifier(navigation))
        }
        // No camera or Library is constructed until the scene resolves its entry.
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
        navigation?.finishReturnIfPortrait()
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
        guard reportedScene !== scene || reportedOrientation != orientation || reportedInsets != insets else { return }
        reportedScene = scene
        reportedOrientation = orientation
        reportedInsets = insets
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

// The scene stays portrait while the camera is visible. The hosting bounds use
// the same portrait size as the SwiftUI controls and preview.
private final class FixedPortraitCameraController: UIViewController {
    private let hosting = UIHostingController(rootView: AnyView(EmptyView()))
    private var portraitSize: CGSize = .zero

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        hosting.safeAreaRegions = []
        hosting.view.backgroundColor = .black
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
    private static var librarySceneIDs: Set<String> = []

    static func supportedOrientations(for scene: UIWindowScene) -> UIInterfaceOrientationMask {
        librarySceneIDs.contains(scene.session.persistentIdentifier) ? .allButUpsideDown : .portrait
    }

    static func setLibraryVisible(_ visible: Bool, in scene: UIWindowScene) {
        let identifier = scene.session.persistentIdentifier
        if visible { librarySceneIDs.insert(identifier) }
        else { librarySceneIDs.remove(identifier) }
    }

    static func removeScene(_ scene: UIScene) {
        librarySceneIDs.remove(scene.session.persistentIdentifier)
    }
}
