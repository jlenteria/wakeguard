package com.bling.wakeguard

import org.junit.Assert.*
import org.junit.Test

class MotivationalQuotesTest {
    @Test fun drawsWithoutRepeatingAndStopsWhenExhausted() {
        val quotes = (1..100).map { "Quote $it" }
        val used = mutableSetOf<String>()
        repeat(100) {
            val selected = chooseUnseenQuote(quotes, used)
            assertNotNull(selected)
            assertTrue(used.add(selected!!))
        }
        assertEquals(quotes.toSet(), used)
        assertNull(chooseUnseenQuote(quotes, used))
        assertNotNull(chooseUnseenQuote(quotes, emptySet()))
    }

    @Test fun duplicateEntriesCannotRepeatAndAnEmptyLibraryReturnsNothing() {
        assertEquals("B", chooseUnseenQuote(listOf("A", "A", "B"), setOf("A")))
        assertNull(chooseUnseenQuote(emptyList(), emptySet()))
    }
}
