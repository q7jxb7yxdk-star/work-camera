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

    func windowScene(_ windowScene: UIWindowScene, didUpdateEffectiveGeometry previousEffectiveGeometry: UIWindowScene.Geometry) {
        NotificationCenter.default.post(name: CameraOrientationPolicy.geometryDidChange, object: windowScene)
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

private final class LibraryHostingController: UIHostingController<AnyView> {
    var entryOrientation: UIInterfaceOrientation = .portrait
    var isReturningToCamera = false
    var onRemoved: (() -> Void)?

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        isReturningToCamera ? .portrait : .allButUpsideDown
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        entryOrientation
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // A detail/editor can cover Library without ending the Library flow.
        guard isBeingDismissed || presentingViewController == nil else { return }
        DispatchQueue.main.async { [weak self] in self?.onRemoved?() }
    }
}

private final class LibraryPresentationAttachmentView: UIView {
    var onWindowChange: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }
}

// This zero-sized bridge remains mounted independently of camera content.
// Presentation is owned by UIKit so preferred orientation is known before entry.
private final class LibraryPresentationController: UIViewController {
    private enum Phase { case idle, presenting, library, restoringPortrait, dismissing }
    private var phase = Phase.idle
    private var wantsLibrary = false
    private var entryOrientation: UIInterfaceOrientation = .portrait
    private var content = AnyView(EmptyView())
    private var hosting: LibraryHostingController?
    private weak var scene: UIWindowScene?
    private weak var presenter: UIViewController?
    private var isProcessingScheduled = false
    private var isShuttingDown = false
    private var returnRequestID: UUID?
    private var presentationGeneration = 0
    var onDidDismiss: (() -> Void)?
    var onError: ((String) -> Void)?
    var onDismissCancelled: ((String) -> Void)?

    override func loadView() {
        let attachment = LibraryPresentationAttachmentView()
        attachment.backgroundColor = .clear
        attachment.isUserInteractionEnabled = false
        attachment.onWindowChange = { [weak self] in self?.scheduleProcessing() }
        view = attachment
        NotificationCenter.default.addObserver(self, selector: #selector(geometryDidChange(_:)),
                                               name: CameraOrientationPolicy.geometryDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDidActivate(_:)),
                                               name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDidDisconnect(_:)),
                                               name: UIScene.didDisconnectNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scheduleProcessing()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scheduleProcessing()
    }

    func update(isPresented: Bool, initialOrientation: UIInterfaceOrientation, content: AnyView) {
        if isPresented && !wantsLibrary {
            switch initialOrientation {
            case .landscapeLeft, .landscapeRight: entryOrientation = initialOrientation
            default: entryOrientation = .portrait
            }
        }
        wantsLibrary = isPresented
        self.content = content
        // Reuse the host so Library's navigation, scroll, and editor state survive.
        hosting?.rootView = content
        scheduleProcessing()
    }

    func requestDismissal() {
        guard !isShuttingDown else { return }
        // A full-screen UIKit host can hide the SwiftUI presenter. Handle Back
        // directly instead of waiting for its representable to receive state.
        wantsLibrary = false
        scheduleProcessing()
    }

    private func scheduleProcessing() {
        guard !isShuttingDown, !isProcessingScheduled else { return }
        isProcessingScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isProcessingScheduled = false
            self.processPresentation()
        }
    }

    private func processPresentation() {
        guard !isShuttingDown else { return }
        if scene == nil { scene = viewIfLoaded?.window?.windowScene }
        guard let scene, scene.activationState == .foregroundActive else { return }
        switch phase {
        case .idle:
            if wantsLibrary { presentLibrary(in: scene) }
        case .library:
            if !wantsLibrary { restorePortrait(in: scene) }
        case .restoringPortrait:
            if wantsLibrary {
                // A quick action can reopen Library while portrait is pending.
                returnRequestID = nil
                phase = .library
                hosting?.isReturningToCamera = false
                UIView.performWithoutAnimation {
                    CameraOrientationPolicy.setLibraryVisible(true, in: scene)
                    presenter?.setNeedsUpdateOfSupportedInterfaceOrientations()
                    hosting?.setNeedsUpdateOfSupportedInterfaceOrientations()
                }
            } else if scene.effectiveGeometry.interfaceOrientation == .portrait {
                dismissLibrary()
            }
        case .presenting, .dismissing:
            break
        }
    }

    private func presentLibrary(in scene: UIWindowScene) {
        guard let root = viewIfLoaded?.window?.rootViewController else { return }
        // An existing root alert must finish; do not present a second modal over it.
        guard root.presentedViewController == nil, !root.isBeingDismissed else {
            // SwiftUI may still be removing a root error alert when the Library
            // request arrives. Retry only this pending, foreground presentation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.wantsLibrary, self.phase == .idle else { return }
                self.scheduleProcessing()
            }
            return
        }
        let host = LibraryHostingController(rootView: content)
        host.entryOrientation = entryOrientation
        host.modalPresentationStyle = .fullScreen
        host.isModalInPresentation = true
        host.view.backgroundColor = .systemBackground
        host.onRemoved = { [weak self, weak host] in
            guard let self, let host else { return }
            self.finishDismissal(of: host)
        }
        hosting = host
        presenter = root
        presentationGeneration += 1
        phase = .presenting
        UIView.performWithoutAnimation {
            CameraOrientationPolicy.setLibraryVisible(true, in: scene)
            root.setNeedsUpdateOfSupportedInterfaceOrientations()
            host.setNeedsUpdateOfSupportedInterfaceOrientations()
            root.present(host, animated: false) { [weak self, weak host] in
                guard let self, let host, self.hosting === host, !self.isShuttingDown else { return }
                self.phase = .library
                self.scheduleProcessing()
            }
        }
        DispatchQueue.main.async { [weak self, weak host] in
            guard let self, let host, self.hosting === host, self.phase == .presenting,
                  host.presentingViewController == nil else { return }
            self.hosting = nil
            self.presenter = nil
            self.phase = .idle
            self.wantsLibrary = false
            UIView.performWithoutAnimation {
                CameraOrientationPolicy.setLibraryVisible(false, in: scene)
                root.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            self.onError?("Could not open Library. Please try again.")
        }
    }

    private func restorePortrait(in scene: UIWindowScene) {
        guard let host = hosting else { return }
        let requestID = UUID()
        returnRequestID = requestID
        phase = .restoringPortrait
        host.isReturningToCamera = true
        UIView.performWithoutAnimation {
            CameraOrientationPolicy.setLibraryVisible(false, in: scene)
            presenter?.setNeedsUpdateOfSupportedInterfaceOrientations()
            host.setNeedsUpdateOfSupportedInterfaceOrientations()
            if scene.effectiveGeometry.interfaceOrientation != .portrait {
                // Keep Library visible until the actual geometry confirms portrait.
                // A denied request must never reveal a landscape camera.
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { [weak self, weak host] error in
                    DispatchQueue.main.async {
                        guard let self, let host, self.hosting === host,
                              self.phase == .restoringPortrait, self.returnRequestID == requestID,
                              !self.wantsLibrary, !self.isShuttingDown else { return }
                        self.returnRequestID = nil
                        self.phase = .library
                        self.wantsLibrary = true
                        host.isReturningToCamera = false
                        UIView.performWithoutAnimation {
                            CameraOrientationPolicy.setLibraryVisible(true, in: scene)
                            self.presenter?.setNeedsUpdateOfSupportedInterfaceOrientations()
                            host.setNeedsUpdateOfSupportedInterfaceOrientations()
                        }
                        self.onDismissCancelled?("Could not return to the camera: \(error.localizedDescription)")
                    }
                }
            }
        }
        scheduleProcessing()
    }

    private func dismissLibrary() {
        guard phase == .restoringPortrait, let host = hosting else { return }
        returnRequestID = nil
        phase = .dismissing
        UIView.performWithoutAnimation {
            host.dismiss(animated: false) { [weak self, weak host] in
                guard let self, let host else { return }
                self.finishDismissal(of: host)
            }
        }
    }

    private func finishDismissal(of host: LibraryHostingController) {
        guard !isShuttingDown, hosting === host, host.presentingViewController == nil else { return }
        let shouldReopen = phase == .dismissing && wantsLibrary
        let generation = presentationGeneration
        // Own all removal paths; a nested editor's disappearance does not enter here.
        hosting = nil
        returnRequestID = nil
        presenter = nil
        phase = .idle
        wantsLibrary = shouldReopen
        if let scene {
            UIView.performWithoutAnimation {
                CameraOrientationPolicy.setLibraryVisible(false, in: scene)
                for window in scene.windows { window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
            }
        }
        if shouldReopen {
            // Keep the Library flow active and consume the latest content/request.
            scheduleProcessing()
            return
        }
        // UIKit lifecycle callbacks may occur inside a SwiftUI representable update.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isShuttingDown, self.presentationGeneration == generation,
                  self.phase == .idle, self.hosting == nil, !self.wantsLibrary else { return }
            self.onDidDismiss?()
        }
    }

    @objc private func geometryDidChange(_ notification: Notification) {
        guard let updatedScene = notification.object as? UIWindowScene, updatedScene === scene else { return }
        scheduleProcessing()
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let activatedScene = notification.object as? UIWindowScene,
              activatedScene === scene || activatedScene === viewIfLoaded?.window?.windowScene else { return }
        scheduleProcessing()
    }

    @objc private func sceneDidDisconnect(_ notification: Notification) {
        guard let disconnectedScene = notification.object as? UIWindowScene, disconnectedScene === scene else { return }
        shutdown()
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        returnRequestID = nil
        presentationGeneration += 1
        onDidDismiss = nil
        onError = nil
        onDismissCancelled = nil
        hosting?.onRemoved = nil
        UIView.performWithoutAnimation {
            if let scene { CameraOrientationPolicy.setLibraryVisible(false, in: scene) }
            presenter?.setNeedsUpdateOfSupportedInterfaceOrientations()
            hosting?.dismiss(animated: false)
        }
        hosting = nil
        presenter = nil
        scene = nil
    }
}

struct LibraryPresentation<Content: View>: UIViewControllerRepresentable {
    let isPresented: Bool
    let initialOrientation: UIInterfaceOrientation
    let content: (@escaping () -> Void) -> Content
    let onDidDismiss: () -> Void
    let onError: (String) -> Void
    let onDismissCancelled: (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = LibraryPresentationController()
        configure(controller)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        if let controller = uiViewController as? LibraryPresentationController { configure(controller) }
    }

    private func configure(_ controller: LibraryPresentationController) {
        controller.onDidDismiss = onDidDismiss
        controller.onError = onError
        controller.onDismissCancelled = onDismissCancelled
        let hostedContent = content { [weak controller] in
            controller?.requestDismissal()
        }
        controller.update(isPresented: isPresented, initialOrientation: initialOrientation, content: AnyView(hostedContent))
    }

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Void) {
        (uiViewController as? LibraryPresentationController)?.shutdown()
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
