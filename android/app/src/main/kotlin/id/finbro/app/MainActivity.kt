package id.finbro.app

import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

// FlutterFragmentActivity is required by local_auth (biometric prompt).
class MainActivity : FlutterFragmentActivity() {
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
        ClockChannel.register(flutterEngine.dartExecutor.binaryMessenger, this)
        PinVerifierChannel.register(flutterEngine.dartExecutor.binaryMessenger, this)
        WidgetChannel.register(flutterEngine.dartExecutor.binaryMessenger, this)
    }

    companion object {
        /** The app is on screen (between onStart and onStop); [BackgroundSyncWorker] then skips. */
        @Volatile
        var visible = false
            private set
    }
}
