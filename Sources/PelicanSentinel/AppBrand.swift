import AppKit
import SwiftUI
import PelicanCore

/// Both variants are derived from the first saved pelican SVG.
enum AppBrand {
    static let logo = load("PelicanLogo")
    static let menuBar: NSImage = {
        let image = load("MenuBarLogo")
        image.size = NSSize(width: 24.4, height: 20)
        image.isTemplate = true
        return image
    }()
    private static func load(_ name: String) -> NSImage {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("Missing bundled logo: \(name).svg")
        }
        return image
    }
}

struct BrandLogo: View {
    var width: CGFloat = 48
    var language: AppLanguage = .english
    var body: some View {
        Image(nsImage: AppBrand.logo).resizable().scaledToFit()
            .padding(width * 0.09)
            .frame(width: width, height: width * 0.88)
            .background(Color(red: 245/255, green: 241/255, blue: 231/255), in: RoundedRectangle(cornerRadius: width * 0.2))
            .accessibilityLabel(language.choose("骑自行车的鹈鹕", "Pelican riding a bicycle"))
    }
}
