package com.bling.wakeguard

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject

/** Platform-independent constants shared by every scheduling path. */
object AlarmDefaults {
    /** Used when an alarm predates per-alarm snooze or omits the value. */
    const val DEFAULT_SNOOZE_MINUTES = 9

    /**
     * Total ring window before the alarm gives up. Mirrors EscalationPolicy.standard.maxRingingDuration
     * in Dart; the scheduler, service, and receiver all key off this one number.
     */
    const val MAX_RINGING_MS = 15 * 60_000L

    /** Escape names, mirroring the Dart `EscapeKind` enum. Keep them in step. */
    const val ESCAPE_FACE = "face"
    const val ESCAPE_OBJECT = "object"
    const val ESCAPE_QR = "qr"
    const val ESCAPE_TAP = "tap"

    /** Camera challenges; Tap is separately opted into. */
    val ALL_ESCAPES = setOf(ESCAPE_FACE, ESCAPE_OBJECT, ESCAPE_QR)

    /**
     * Unknown names are dropped. A legacy Pattern-only record is an Object draft
     * that needs setup, never a silent Tap fallback.
     */
    fun escapesFrom(values: Collection<String>?): Set<String> {
        if (values == null) return setOf(ESCAPE_FACE)
        val parsed = values
            .map { it.trim() }
            .filter { it in ALL_ESCAPES || it == ESCAPE_TAP }
            .toSet()
        return parsed.ifEmpty { setOf(ESCAPE_OBJECT) }
    }

    fun needsChallengeSetup(values: Collection<String>?): Boolean = values != null &&
        values.none { it in ALL_ESCAPES || it == ESCAPE_TAP }

    fun escapesFromExtra(encoded: String?): Set<String> =
        escapesFrom(encoded?.split(','))
}

/**
 * Native alarm record: source of truth across process death, reboot, or the Dart isolate dying.
 */
data class StoredAlarm(
    val id: String,
    val hour: Int,
    val minute: Int,
    val label: String,
    val enabled: Boolean,
    val repeatDaily: Boolean,
    val weekdays: Set<Int>,
    val qrValue: String,
    val stepCount: Int,
    /** Generated tone family: pulse | siren | radar | gong. */
    val soundPack: String = "pulse",
    /** Minutes the user may surrender this alarm for; 0 disables snoozing. */
    val snoozeMinutes: Int = AlarmDefaults.DEFAULT_SNOOZE_MINUTES,
    /** Escapes this alarm offers: a subset of [AlarmDefaults.ALL_ESCAPES]. */
    val escapes: Set<String> = setOf(AlarmDefaults.ESCAPE_FACE),
    val checkInMinutes: Int = 0,
    val objectTarget: String = "sink",
    val objectVerified: Boolean = false,
    val needsSetup: Boolean = false,
    val skipUntilMillis: Long = 0L,
    val nextTriggerAt: Long = 0L,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("hour", hour)
        put("minute", minute)
        put("label", label)
        put("enabled", enabled)
        put("repeatDaily", repeatDaily)
        put("weekdays", org.json.JSONArray(weekdays.toList()))
        put("qrValue", qrValue)
        put("stepCount", stepCount)
        put("soundPack", soundPack)
        put("snoozeMinutes", snoozeMinutes)
        put("escapes", org.json.JSONArray(escapes.sorted()))
        put("checkInMinutes", checkInMinutes)
        put("objectTarget", objectTarget)
        put("objectVerified", objectVerified)
        put("needsSetup", needsSetup)
        put("skipUntilMillis", skipUntilMillis)
        put("nextTriggerAt", nextTriggerAt)
    }

    /** Stable positive notification id derived from the opaque string id. */
    val notificationId: Int get() = notificationIdFor(id)

    companion object {
        /**
         * Stable positive notification id for a bare id. Used even when disarming an alarm no longer
         * in the store: PendingIntents match on request code plus data URI, so the id suffices.
         */
        fun notificationIdFor(id: String): Int = (id.hashCode() and 0x7FFFFFFF).coerceAtLeast(1)

        fun fromJson(raw: String): StoredAlarm? = runCatching {
            val json = JSONObject(raw)
            val rawEscapes = json.optJSONArray("escapes")?.let { array ->
                (0 until array.length()).map { array.getString(it) }
            }
            val needsSetup = json.optBoolean("needsSetup", false) ||
                AlarmDefaults.needsChallengeSetup(rawEscapes) ||
                (rawEscapes?.contains(AlarmDefaults.ESCAPE_OBJECT) == true &&
                    json.optString("objectTarget") !in ObjectTargets.names)
            StoredAlarm(
                id = json.getString("id"),
                hour = json.getInt("hour"),
                minute = json.getInt("minute"),
                label = json.optString("label", "Wake up"),
                enabled = !needsSetup && json.optBoolean("enabled", true),
                repeatDaily = json.optBoolean("repeatDaily", true),
                weekdays = json.optJSONArray("weekdays")
                    ?.let { array -> (0 until array.length()).map { array.getInt(it) } }
                    ?.filter { it in 1..7 }?.toSet()
                    ?: emptySet(),
                qrValue = json.optString("qrValue", ""),
                stepCount = json.optInt("stepCount", 2),
                soundPack = json.optString("soundPack", "pulse"),
                snoozeMinutes = json.optInt(
                    "snoozeMinutes",
                    AlarmDefaults.DEFAULT_SNOOZE_MINUTES,
                ).coerceIn(0, 60),
                escapes = AlarmDefaults.escapesFrom(rawEscapes),
                checkInMinutes = json.optInt("checkInMinutes", 0).takeIf { it in setOf(0, 3, 5, 10) } ?: 0,
                objectTarget = json.optString("objectTarget", "sink").takeIf { it in ObjectTargets.names } ?: "sink",
                objectVerified = json.optString("objectTarget") in ObjectTargets.names && json.optBoolean("objectVerified", false),
                needsSetup = needsSetup,
                skipUntilMillis = json.optLong("skipUntilMillis", 0L),
                nextTriggerAt = json.optLong("nextTriggerAt", 0L),
            )
        }.getOrNull()
    }
}

/**
 * Storage for the native alarm set, backed by device-protected storage so [BootReceiver] can
 * reschedule after a locked reboot (BOOT_COMPLETED only arrives after first unlock).
 */
object AlarmStore {
    private const val PREFS = "wakeguard.alarms.v2"
    private const val DEVICE_PROTECTED_PREFS = "wakeguard.alarms.v2.dp"

    private fun prefs(context: Context, deviceProtected: Boolean): SharedPreferences? =
        runCatching {
            if (deviceProtected &&
                android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.N
            ) {
                context.createDeviceProtectedStorageContext()
                    .getSharedPreferences(DEVICE_PROTECTED_PREFS, Context.MODE_PRIVATE)
            } else {
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            }
        }.getOrNull()

    fun put(context: Context, alarm: StoredAlarm) {
        val payload = alarm.toJson().toString()
        // Device-protected is canonical, including before first unlock.
        check(prefs(context, true)?.edit()?.putString(alarm.id, payload)?.commit() == true) {
            "Could not persist alarm configuration"
        }
        prefs(context, false)?.edit()?.putString(alarm.id, payload)?.apply()
    }

    fun remove(context: Context, id: String) {
        // Tombstones prevent an inaccessible/stale credential mirror resurrecting a deletion.
        check(prefs(context, true)?.edit()?.putString(id, "")?.commit() == true) { "Could not remove alarm configuration" }
        prefs(context, false)?.edit()?.remove(id)?.commit()
    }

    /**
     * Reads both stores, preferring device-protected on a duplicate. [runCatching] matters: reading
     * credential storage before first unlock throws in LOCKED_BOOT_COMPLETED. Device-protected wins
     * ties because it can hold the newer pre-unlock write.
     */
    fun all(context: Context): List<StoredAlarm> {
        val fromCredential = runCatching { prefs(context, false)?.all }.getOrNull()
            ?: emptyMap()
        val fromDeviceProtected = runCatching { prefs(context, true)?.all }.getOrNull()
            ?: emptyMap()
        return (fromCredential + fromDeviceProtected).values
            .filterIsInstance<String>()
            .mapNotNull(StoredAlarm::fromJson)
            .distinctBy { it.id }
            .sortedBy { it.hour * 60 + it.minute }
    }

    fun get(context: Context, id: String): StoredAlarm? {
        val raw = runCatching { prefs(context, true)?.getString(id, null) }.getOrNull()
            ?: runCatching { prefs(context, false)?.getString(id, null) }.getOrNull()
        return raw?.let(StoredAlarm::fromJson)
    }
}
