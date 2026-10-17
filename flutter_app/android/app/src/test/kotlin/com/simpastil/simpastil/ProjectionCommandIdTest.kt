package com.simpastil.simpastil

import java.io.InputStreamReader
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProjectionCommandIdTest {
    @Test
    fun `matches UUID v5 reference and shared take skip canonical bytes`() {
        val fixture = javaClass.getResourceAsStream("/projection-command-ids-v1.json")
            ?.use { InputStreamReader(it).readText() }
            ?: error("Shared projection command fixture is missing")

        assertEquals(
            "21f7f8de-8051-5b89-8680-0195ef798b6a",
            WidgetProjectionContract.uuidV5("www.widgets.com"),
        )

        val stringField = Regex("\"([^\"]+)\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"")
        val projectionSection = fixture.substringAfter("\"widgetProjection\": {")
            .substringBefore("\n  }")
        val projectionFields = stringField.findAll(projectionSection)
            .associate { it.groupValues[1] to it.groupValues[2].replace("\\\"", "\"") }
        val generation = Regex("\"sessionGeneration\"\\s*:\\s*(\\d+)")
            .find(projectionSection)!!.groupValues[1].toInt()
        assertEquals(
            projectionFields.getValue("canonicalKey"),
            WidgetProjectionContract.widgetProjectionCanonicalKey(
                projectionFields.getValue("userId"),
                generation,
                projectionFields.getValue("occurrenceId"),
            ),
        )

        val actionSection = fixture.substringAfter("\"widgetActionVectors\": [")
            .substringBefore("\n  ]")
        val vectors = Regex("""\{([^{}]*)\}""").findAll(actionSection).map { match ->
            stringField.findAll(match.groupValues[1])
                .associate { it.groupValues[1] to it.groupValues[2].replace("\\\"", "\"") }
        }.toList()

        assertEquals(2, vectors.size)
        val ids = vectors.map { vector ->
            val projectionId = vector.getValue("projectionId")
            val occurrenceId = vector.getValue("occurrenceId")
            val action = vector.getValue("action")
            val canonicalKey = WidgetProjectionContract.widgetActionCanonicalKey(
                projectionId,
                occurrenceId,
                action,
            )
            assertEquals(vector.getValue("canonicalKey"), canonicalKey)
            WidgetProjectionContract.widgetActionCommandId(
                projectionId,
                occurrenceId,
                action,
            )
        }
        assertNotEquals(ids[0], ids[1])
        assertTrue(ids.all {
            it.matches(Regex("""^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"""))
        })
    }
}
