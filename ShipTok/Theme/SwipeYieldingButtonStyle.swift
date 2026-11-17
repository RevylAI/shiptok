import SwiftUI

// A tap gesture fails once the finger moves, so a swipe that starts on the button still reaches the feed's drag; a plain Button keeps the touch.
struct SwipeYieldingButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onTapGesture { configuration.trigger() }
    }
}

extension PrimitiveButtonStyle where Self == SwipeYieldingButtonStyle {
    static var swipeYielding: SwipeYieldingButtonStyle { SwipeYieldingButtonStyle() }
}
