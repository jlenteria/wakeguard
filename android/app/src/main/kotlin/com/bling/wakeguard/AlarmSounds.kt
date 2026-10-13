package com.bling.wakeguard

/**
 * Maps a [StoredAlarm.soundPack] to a bundled raw resource. One pack is one tone, played identically
 * by the alarm and preview. Lookup is defensive (generated names, typo-safe) and always falls back
 * to another tone: a silent alarm is the exact failure this app exists to prevent.
 */
object AlarmSounds {

    const val DEFAULT_PACK = "pulse"

    /** The generated tier that is used as "the" tone for every pack. */
    private const val TONE = "critical"

    /** Tried only if [TONE] is missing for a pack. */
    private const val FALLBACK_TONE = "gentle"

    /** The families [tool/generate_alarms.py] renders. */
    private val PACKS = listOf("pulse", "siren", "radar", "gong")

    /** The raw resource for [pack]. Never 0. */
    fun resourceFor(context: android.content.Context, pack: String?): Int {
        val safePack = pack?.takeIf { it in PACKS } ?: DEFAULT_PACK
        // Try this pack, then other packs; ends on a compile-time constant, so never 0.
        val candidates = buildList {
            add("tone_${safePack}_$TONE")
            add("tone_${safePack}_$FALLBACK_TONE")
            for (fallbackPack in PACKS) {
                add("tone_${fallbackPack}_$TONE")
                add("tone_${fallbackPack}_$FALLBACK_TONE")
            }
        }
        for (name in candidates) {
            val id = context.resources.getIdentifier(name, "raw", context.packageName)
            if (id != 0) return id
        }
        return R.raw.tone_pulse_gentle
    }

    /** Every selectable pack, for the Dart UI and health reporting. */
    fun packs(): List<String> = PACKS
}
