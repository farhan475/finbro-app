package id.finbro.app

import android.content.Context
import android.os.SystemClock
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * `id.finbro.app/clock`: time sources the user cannot set, for the app lock.
 *
 * `now` returns `elapsedRealtime` (ms since boot, keeps counting in deep
 * sleep) and `bootCount` (`Settings.Global.BOOT_COUNT`, null if the ROM does
 * not provide it) so Dart can tell whether a persisted elapsedRealtime value
 * belongs to the current boot.
 */
object ClockChannel {
    private const val NAME = "id.finbro.app/clock"

    fun register(messenger: BinaryMessenger, context: Context) {
        val resolver = context.applicationContext.contentResolver
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "now" -> {
                    // Read first: it is the value the caller measures with.
                    val elapsed = SystemClock.elapsedRealtime()
                    val bootCount = try {
                        Settings.Global.getInt(resolver, Settings.Global.BOOT_COUNT)
                    } catch (e: Settings.SettingNotFoundException) {
                        null
                    }
                    result.success(mapOf("elapsedRealtime" to elapsed, "bootCount" to bootCount))
                }
                else -> result.notImplemented()
            }
        }
    }
}
