// MobCiGauge — tier-2 plugin Compose factory.
//
// Until the plugin merge engine wires plugin Kotlin into the build
// automatically, the host app developer copies this content into
// MobBridge.kt (alongside the MobNativeViewRegistry definition) and
// arranges MobCiGaugePlugin.register() to run at startup — the documented
// workflow for native components today.

object MobCiGaugePlugin {
    fun register() {
        MobNativeViewRegistry.register("MobCiGauge_View") { props, _send ->
            MobCiGaugeComposable(props)
        }
    }
}

@Composable
private fun MobCiGaugeComposable(props: Map<String, Any?>) {
    val label = (props["label"] as? String) ?: "MobCiGauge"
    Text(label)
}
