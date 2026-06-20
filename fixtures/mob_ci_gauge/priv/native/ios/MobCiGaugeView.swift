// MobCiGaugeView — tier-2 plugin SwiftUI view.
// Mirrors the Android Compose factory in priv/native/android/MobCiGauge.kt.
// Once the host iOS init wires plugin views into the native_view
// dispatch, this is registered under `"MobCiGauge_View"` (the Mob.Component
// module-name encoding).
import SwiftUI

struct MobCiGaugeView: View {
    let props: [String: Any]

    var body: some View {
        let label = props["label"] as? String ?? "MobCiGauge"
        Text(label)
    }
}
