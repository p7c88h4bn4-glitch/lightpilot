import CoreAudioKit
import SwiftUI
import UIKit

public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {

    private var audioUnit: LightPilotAudioUnit?
    private var hosting: UIHostingController<AnyView>?
    private var viewModel: LightViewModel?

    // The host may call this off the main thread; build the AU there and hop to main for UI.
    nonisolated public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try LightPilotAudioUnit(componentDescription: componentDescription, options: [])
        let attach: () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.attach(au)
            }
        }
        if Thread.isMainThread {
            attach()
        } else {
            DispatchQueue.main.async(execute: attach)
        }
        return au
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)
        preferredContentSize = CGSize(width: 420, height: 600)
        buildUIIfReady()
    }

    private func attach(_ au: LightPilotAudioUnit) {
        audioUnit = au
        if isViewLoaded { buildUIIfReady() }
    }

    private func buildUIIfReady() {
        guard hosting == nil, let au = audioUnit else { return }
        let vm = LightViewModel(core: au.core) { [weak au] target, value in
            au?.setFromUI(target, value)
        }
        viewModel = vm
        let root = AnyView(ControlPanelView(vm: vm).preferredColorScheme(.dark))
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        hosting = host
    }
}
