import SwiftUI

struct VinylPressingView: View {
    let diameter: CGFloat

    var body: some View {
        Rectangle().fill(.black)
            .colorEffect(ShaderLibrary.bundle(Bundle(for: VinylShaderBundle.self))
                .vinylDisc(.float2(Float(diameter), Float(diameter))))
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
    }
}

private final class VinylShaderBundle: NSObject {}
