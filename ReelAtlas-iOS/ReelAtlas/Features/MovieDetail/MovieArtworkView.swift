import SwiftUI
import UIKit

struct CachedFileImage:View {
    let url:URL?
    var body:some View {
        Group {
            if let url,let image=UIImage(contentsOfFile:url.path){Image(uiImage:image).resizable().scaledToFill()}
            else { Color.clear }
        }
    }
}
