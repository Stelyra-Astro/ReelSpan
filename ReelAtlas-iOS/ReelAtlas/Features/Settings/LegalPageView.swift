import SwiftUI

struct LegalPageView:View {
    let page:LegalPage
    var body:some View { ScrollView{Text(page.body).frame(maxWidth:.infinity,alignment:.leading).padding(18).textSelection(.enabled)}.navigationTitle(page.title).navigationBarTitleDisplayMode(.inline) }
}
