package id.finbro.app

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity is required by local_auth (biometric prompt).
class MainActivity : FlutterFragmentActivity() {
    /** Kotlin→Dart side of [WidgetChannel] on the app engine (`open`). */
    private var widgetEvents: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Financial data: keep it out of screenshots, screen recording and the
        // Recents thumbnail — in shipped (non-debuggable) builds. Debug builds
        // allow screen capture so development/testing can see the UI; the
        // security property for users is unchanged (release keeps FLAG_SECURE).
        val debuggable = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (!debuggable) {
            window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
            if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(false)
        }
        BackgroundSyncWorker.schedule(this)
        // Cold start from a widget section: Dart reads it after its first frame.
        captureWidgetTarget(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (captureWidgetTarget(intent)) widgetEvents?.invokeMethod("open", null)
    }

    override fun onStart() {
        super.onStart()
        visible = true
    }

    override fun onStop() {
        visible = false
        super.onStop()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        ClockChannel.register(messenger, this)
        PinVerifierChannel.register(messenger, this)
        WidgetChannel.register(messenger, this)
        widgetEvents = MethodChannel(messenger, WidgetChannel.NAME)
    }

    /** Stores the widget section of [intent] (once: the extra is removed). */
    private fun captureWidgetTarget(intent: Intent?): Boolean {
        val target = intent?.getStringExtra(FinBroWidgetProvider.EXTRA_TARGET) ?: return false
        intent.removeExtra(FinBroWidgetProvider.EXTRA_TARGET)
        pendingWidgetTarget = target
        return true
    }

    companion object {
        /** The app is on screen (between onStart and onStop); [BackgroundSyncWorker] then skips. */
        @Volatile
        var visible = false
            private set

        @Volatile
        private var pendingWidgetTarget: String? = null

        /** The widget section the app was last opened from, cleared on read. */
        fun takeWidgetTarget(): String? = pendingWidgetTarget.also { pendingWidgetTarget = null }
    }
}
