import SceneKit
import SwiftUI

/// The depth surface is built only from cells where Bearing V1 detected a candidate.
struct BearingDepthScene: UIViewRepresentable {
    let result: BearingLayerPresentation
    let onSelect: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(red:0.06,green:0.08,blue:0.10,alpha:1)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        let tap = UITapGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.tap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.parent = self
        var hasher = Hasher()
        hasher.combine(result.nx); hasher.combine(result.ny)
        hasher.combine(result.dxMeters); hasher.combine(result.dyMeters)
        for depth in result.depthYX { hasher.combine(depth) }
        for cpt in result.cpts { hasher.combine(cpt.id); hasher.combine(cpt.x); hasher.combine(cpt.y) }
        let signature = hasher.finalize()
        guard signature != context.coordinator.signature else { return }
        context.coordinator.signature = signature
        view.scene = makeScene()
    }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        guard let range = result.depthRange else { return scene }
        let dx = result.dxMeters, dy = result.dyMeters
        let width = Double(result.nx) * dx, height = Double(result.ny) * dy
        var vertices = [SCNVector3]()
        var triangles = [[UInt32]](repeating:[],count:16)
        for y in 0..<result.ny { for x in 0..<result.nx {
            guard let depth = result.depth(x:x,y:y) else { continue }
            let base = UInt32(vertices.count)
            let left = Double(x)*dx, right = Double(x+1)*dx
            let near = -Double(y)*dy, far = -Double(y+1)*dy
            let vertical = Float(-depth)
            vertices.append(contentsOf:[SCNVector3(Float(left),vertical,Float(near)),
                                       SCNVector3(Float(right),vertical,Float(near)),
                                       SCNVector3(Float(left),vertical,Float(far)),
                                       SCNVector3(Float(right),vertical,Float(far))])
            let t = range.upperBound > range.lowerBound
                ? (depth-range.lowerBound)/(range.upperBound-range.lowerBound) : 0.5
            let bin = min(15,max(0,Int(t*15)))
            triangles[bin].append(contentsOf:[base,base+1,base+2,base+1,base+3,base+2])
        } }
        if !vertices.isEmpty {
            let active = triangles.enumerated().filter { !$0.element.isEmpty }
            let source = SCNGeometrySource(vertices:vertices)
            let elements = active.map { SCNGeometryElement(indices:$0.element,primitiveType:.triangles) }
            let geometry = SCNGeometry(sources:[source],elements:elements)
            geometry.materials = active.map { entry in
                let material = SCNMaterial()
                material.diffuse.contents = UIColor(depthColor(Double(entry.offset)/15))
                material.lightingModel = .constant
                material.isDoubleSided = true
                return material
            }
            let surface = SCNNode(geometry:geometry)
            surface.name = "bearingSurface"
            scene.rootNode.addChildNode(surface)
        }
        let markerRadius = CGFloat(max(0.15,min(dx,dy)*0.16))
        for cpt in result.cpts where (0..<result.nx).contains(cpt.x) && (0..<result.ny).contains(cpt.y) {
            let sphere = SCNSphere(radius:markerRadius)
            sphere.firstMaterial?.diffuse.contents = UIColor.white
            sphere.firstMaterial?.lightingModel = .constant
            let node = SCNNode(geometry:sphere)
            let depth = result.depth(x:cpt.x,y:cpt.y) ?? 0
            node.position = SCNVector3(Float((Double(cpt.x)+0.5)*dx),Float(-depth)+Float(markerRadius*1.5),
                                       Float(-(Double(cpt.y)+0.5)*dy))
            node.name = "CPT \(cpt.id)"
            scene.rootNode.addChildNode(node)
        }
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zFar = max(1000, max(width,height)*10)
        camera.position = SCNVector3(Float(width*0.9),Float(max(width,height)*1.1),
                                     Float(height*0.9))
        camera.look(at:SCNVector3(Float(width/2),Float(-(range.lowerBound+range.upperBound)/2),
                                  Float(-height/2)))
        scene.rootNode.addChildNode(camera)
        return scene
    }

    private func depthColor(_ t: Double) -> Color {
        let stops: [(Double,Double,Double)] = [
            (0.99,0.43,0.08), (0.99,0.83,0.15), (0.23,0.79,0.40),
            (0.05,0.66,0.69), (0.06,0.28,0.66)
        ]
        let scaled = min(1,max(0,t))*4
        let low = min(3,Int(scaled)), fraction = scaled-Double(low)
        let a = stops[low], b = stops[low+1]
        return Color(red:a.0+(b.0-a.0)*fraction,
                     green:a.1+(b.1-a.1)*fraction,
                     blue:a.2+(b.2-a.2)*fraction)
    }

    @MainActor final class Coordinator: NSObject {
        var parent: BearingDepthScene
        weak var view: SCNView?
        var signature: Int?
        private var selectionNode: SCNNode?
        init(_ parent: BearingDepthScene) { self.parent = parent }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard let view, recognizer.state == .ended else { return }
            let point = recognizer.location(in:view)
            guard let hit = view.hitTest(point,options:nil).first(where: { $0.node.name == "bearingSurface" }) else { return }
            let dx = parent.result.dxMeters, dy = parent.result.dyMeters
            let x = Int(floor(Double(hit.worldCoordinates.x)/dx))
            let y = Int(floor(-Double(hit.worldCoordinates.z)/dy))
            guard (0..<parent.result.nx).contains(x), (0..<parent.result.ny).contains(y),
                  parent.result.depth(x:x,y:y) != nil else { return }
            selectionNode?.removeFromParentNode()
            let radius = CGFloat(max(0.2,min(dx,dy)*0.24))
            let sphere = SCNSphere(radius:radius)
            sphere.firstMaterial?.diffuse.contents = UIColor.systemPurple
            sphere.firstMaterial?.lightingModel = .constant
            let marker = SCNNode(geometry:sphere)
            marker.name = "selectedBearingCell"
            marker.position = SCNVector3(hit.worldCoordinates.x,hit.worldCoordinates.y + Float(radius*1.3),
                                         hit.worldCoordinates.z)
            view.scene?.rootNode.addChildNode(marker)
            selectionNode = marker
            parent.onSelect(x,y)
        }
    }
}
