import SwiftUI
import RealityKit
import ARKit

/// Shared holder for the persistent ARView instance.
@MainActor
final class ARViewHolder {
    var view: ARView?
}

/// UIViewControllerRepresentable wrapping ARView.
/// Using a VC prevents SwiftUI from re-parenting the UIKit view
/// on every @State change (_UIReparentingView warning).
struct FindItemARContainer: UIViewControllerRepresentable {
    let holder: ARViewHolder

    func makeUIViewController(context: Context) -> ARViewController {
        let vc = ARViewController()
        holder.view = vc.arView
        return vc
    }

    func updateUIViewController(_ vc: ARViewController, context: Context) {}
}

// MARK: - ARViewController

final class ARViewController: UIViewController {
    let arView = ARView(frame: .zero)

    override func viewDidLoad() {
        super.viewDidLoad()
        arView.environment.background = .cameraFeed()
        arView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(arView)
        NSLayoutConstraint.activate([
            arView.topAnchor.constraint(equalTo: view.topAnchor),
            arView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            arView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            arView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}

// MARK: - Marker Builder

extension FindItemARContainer {
    /// Create a floating text marker entity at the given world transform.
    @MainActor
    static func createMarkerEntity(
        name: String,
        color: UIColor = .systemBlue,
        at transform: simd_float4x4
    ) -> AnchorEntity {
        let anchor = AnchorEntity(world: transform)
        let mesh = MeshResource.generateText(
            name,
            extrusionDepth: 0.01,
            font: .systemFont(ofSize: 0.05, weight: .bold)
        )
        let material = SimpleMaterial(color: color, isMetallic: false)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position.y += 0.08
        // Center the text horizontally
        let bounds = entity.visualBounds(relativeTo: entity)
        entity.position.x -= bounds.extents.x / 2
        anchor.addChild(entity)
        return anchor
    }
}
