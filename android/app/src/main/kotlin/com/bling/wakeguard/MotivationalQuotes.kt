package com.bling.wakeguard

import android.content.Context
import org.json.JSONArray
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Draw without replacement; quote text is the ID so reordering the library is safe. */
internal fun chooseUnseenQuote(quotes: List<String>, used: Set<String>): String? =
    quotes.filterNot { it in used }.distinct().randomOrNull()

object MotivationalQuotes {
    /** Called only after dismissal. A quote failure must never keep an alarm ringing. */
    @Synchronized
    fun next(context: Context): String? = try {
        val raw = context.assets.open("motivational_quotes.json").bufferedReader().use { it.readText() }
        val data = JSONArray(raw)
        val quotes = (0 until data.length()).map { data.getString(it).trim() }.filter { it.isNotEmpty() }
        val day = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())
        val preferences = context.getSharedPreferences("wakeguard.motivationalQuotes", Context.MODE_PRIVATE)
        val used = if (preferences.getString("day", null) == day) {
            preferences.getStringSet("used", emptySet()).orEmpty().toSet()
        } else emptySet()
        val quote = chooseUnseenQuote(quotes, used)
        if (quote == null) null else {
            // Persist before showing, including across process restarts.
            val saved = preferences.edit().putString("day", day)
                .putStringSet("used", used + quote).commit()
            if (saved) quote else null
        }
    } catch (error: Exception) {
        android.util.Log.w("WakeGuard", "Could not load a motivational quote", error)
        null
    }
}
