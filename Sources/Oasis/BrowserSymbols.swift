import SwiftUI

struct SiteIcon: View {
  let url: URL
  var body: some View {
    Text(String(url.displayHost.prefix(1)).uppercased())
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(Color.oasisAccent)
      .frame(width: 30, height: 30)
      .background(Color.oasisAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
      .accessibilityHidden(true)
  }
}
