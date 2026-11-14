import SwiftUI
import UIKit

/// The share sheet's entry point: what the system makes when someone picks Phleet in another
/// app's share menu.
///
/// It hosts one SwiftUI screen and hands it what was shared. Everything the screen does is in
/// `ShareModel`, which is the app's code and is tested with the app.
final class ShareViewController: UIViewController {

    private var model: ShareModel?

    override func viewDidLoad() {
        super.viewDidLoad()

        let model = ShareModel(actions: QuickActions.live())
        self.model = model

        let screen = ShareView(
            model: model,
            cancel: { [weak self] in self?.cancel() },
            done: { [weak self] in self?.done() }
        )
        let host = UIHostingController(rootView: screen)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        host.didMove(toParent: self)

        let context = extensionContext
        Task {
            await SharedItems.load(from: context, into: model)
        }
        Task {
            await model.loadAgents()
        }
    }

    /// The person backed out. Nothing was sent.
    private func cancel() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    /// The message was accepted. Nothing goes back to the app that shared: this sheet sends
    /// outward only.
    private func done() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
