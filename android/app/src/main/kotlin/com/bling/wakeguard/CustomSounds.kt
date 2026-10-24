package com.bling.wakeguard

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.OpenableColumns
import java.io.File
import java.util.UUID

/**
 * User-supplied alarm tones. A picked document is copied into device-protected storage so it still
 * plays after a reboot before first unlock, and never depends on the source app or folder surviving.
 * Anything missing or unplayable falls back to a bundled tone at ring time: a silent alarm is the
 * failure this app exists to prevent.
 */
object CustomSounds {

    const val MAX_BYTES = 25L * 1024 * 1024

    /** Unreferenced files younger than this are kept: an editor may have just picked one. */
    private const val SWEEP_MIN_AGE_MS = 60L * 60_000L

    class Imported(val id: String, val name: String)

    private fun dir(context: Context): File =
        File(context.createDeviceProtectedStorageContext().filesDir, "custom_sounds").apply { mkdirs() }

    /** The stored file for [id], or null when unset, malformed, missing or empty. */
    fun fileFor(context: Context, id: String?): File? {
        if (id.isNullOrBlank() || id != File(id).name) return null
        return File(dir(context), id).takeIf { it.isFile && it.length() > 0L }
    }

    /** Copies [uri] into private storage and verifies it decodes as audio. Throws a user-readable message. */
    fun import(context: Context, uri: Uri): Imported {
        val resolver = context.contentResolver
        var name = ""
        var size = -1L
        runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (!cursor.moveToFirst()) return@use
                val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (nameColumn >= 0 && !cursor.isNull(nameColumn)) name = cursor.getString(nameColumn).orEmpty()
                if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) size = cursor.getLong(sizeColumn)
            }
        }
        require(size <= MAX_BYTES) { "That file is larger than 25 MB. Choose a shorter sound." }

        val extension = name.substringAfterLast('.', "").lowercase().filter { it.isLetterOrDigit() }.take(5)
            .ifEmpty { "audio" }
        val id = "${UUID.randomUUID()}.$extension"
        val target = File(dir(context), id)
        try {
            val source = resolver.openInputStream(uri) ?: throw IllegalArgumentException("Could not open that file.")
            source.use { input ->
                target.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        require(total <= MAX_BYTES) { "That file is larger than 25 MB. Choose a shorter sound." }
                        output.write(buffer, 0, read)
                    }
                }
            }
            require(isPlayableAudio(target)) { "That file is not a playable audio file." }
        } catch (failure: Throwable) {
            target.delete()
            if (failure is IllegalArgumentException) throw failure
            android.util.Log.w("WakeGuard", "Custom sound import failed", failure)
            throw IllegalArgumentException("Could not read that file.")
        }
        val shown = name.trim().ifEmpty { "Custom sound" }
        return Imported(id, shown.take(80))
    }

    private fun isPlayableAudio(file: File): Boolean {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.absolutePath)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes" &&
                (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L) > 0L
        } catch (_: Exception) {
            false
        } finally {
            runCatching { retriever.release() }
        }
    }

    private fun prefs(context: Context) = context.createDeviceProtectedStorageContext()
        .getSharedPreferences("wakeguard.custom_sounds.v1", Context.MODE_PRIVATE)

    /** Restarts the sweep grace period, so a just-released tone survives an Undo. */
    fun touch(context: Context, id: String?) {
        val file = fileFor(context, id) ?: return
        runCatching { file.setLastModified(System.currentTimeMillis()) }
    }

    /**
     * Records the tones saved alarms use, including switched-off ones the native store dropped.
     * A tone leaving the set is touched rather than deleted, so a deleted alarm can be undone.
     */
    @Synchronized fun retain(context: Context, ids: Collection<String>) {
        val next = ids.filter { it.isNotBlank() && it == File(it).name }.toSet()
        val previous = prefs(context).getStringSet(KEY_RETAINED, emptySet()).orEmpty()
        (previous - next).forEach { touch(context, it) }
        prefs(context).edit().putStringSet(KEY_RETAINED, next).commit()
    }

    private const val KEY_RETAINED = "retained"

    /** Removes files no alarm or live session references, sparing very recent picks. */
    fun sweep(context: Context) {
        runCatching {
            val referenced = buildSet {
                AlarmStore.all(context).forEach { add(it.customSound) }
                AlarmSessions.all(context).forEach { add(it.alarm.customSound) }
                addAll(prefs(context).getStringSet(KEY_RETAINED, emptySet()).orEmpty())
            }
            val cutoff = System.currentTimeMillis() - SWEEP_MIN_AGE_MS
            dir(context).listFiles()?.forEach { file ->
                if (file.name !in referenced && file.lastModified() < cutoff) file.delete()
            }
        }.onFailure { android.util.Log.w("WakeGuard", "Custom sound cleanup failed", it) }
    }
}
