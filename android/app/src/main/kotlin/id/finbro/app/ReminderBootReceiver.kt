package id.finbro.app

import android.app.AlarmManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver

/**
 * Replaces the plugin's boot receiver in the manifest. Before the plugin
 * re-arms its stored schedule, reminders stored as exact alarms are switched
 * to inexact when Android no longer allows exact alarms (user revoked
 * "Alarm & pengingat"). Otherwise the plugin would drop them from its cache
 * and they would be lost until FinBro is opened again.
 */
class ReminderBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!canScheduleExact(context)) downgradeExactAlarms(context)
        ScheduledNotificationBootReceiver().onReceive(context, intent)
    }

    private fun canScheduleExact(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return false
        return alarms.canScheduleExactAlarms()
    }

    /**
     * The plugin stores its schedule as Gson JSON in SharedPreferences
     * `scheduled_notifications` (same key); enum names are serialized
     * verbatim. Quotes inside payload strings are escaped, so only the
     * structural `scheduleMode` fields match.
     */
    private fun downgradeExactAlarms(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val json = prefs.getString(PREFS, null) ?: return
        val downgraded = json
            .replace("\"scheduleMode\":\"exactAllowWhileIdle\"", "\"scheduleMode\":\"inexactAllowWhileIdle\"")
            .replace("\"scheduleMode\":\"exact\"", "\"scheduleMode\":\"inexact\"")
        if (downgraded != json) prefs.edit().putString(PREFS, downgraded).commit()
    }

    private companion object {
        const val PREFS = "scheduled_notifications"
    }
}
