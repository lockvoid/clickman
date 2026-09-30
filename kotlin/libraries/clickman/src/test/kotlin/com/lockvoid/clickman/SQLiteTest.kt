package com.lockvoid.clickman

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertSame

class SQLiteTest {
    private val directory: File = Files.createTempDirectory("clickman-sqlite").toFile()
    private val db: SQLiteConnection = BundledSQLiteDriver().open(File(directory, "test.sqlite").path)

    @AfterTest
    fun tearDown() {
        db.close()
        directory.deleteRecursively()
    }

    private fun tables(): List<String> = db.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") { it.getText(0) }

    @Test
    fun aScriptSplitsIntoItsStatementsWithoutComments() {
        val script = "-- a comment; with a semicolon\nCREATE TABLE a (x); -- trailing;\n\nCREATE TABLE b (y);\n"

        assertEquals(listOf("CREATE TABLE a (x)", "CREATE TABLE b (y)"), sqlStatements(script).map { it.trim() })
        assertEquals(3, sqlStatements(QueueSchema.create).size)
        assertEquals(3, sqlStatements(QueueSchema.upgrade).size)
    }

    @Test
    fun execRunsOnlyTheFirstStatementOfAString() {
        db.exec("CREATE TABLE a (x); CREATE TABLE b (y)")

        assertEquals(listOf("a"), tables())
    }

    @Test
    fun aTransactionCommitsItsWork() {
        db.exec("CREATE TABLE a (x)")

        val answer = db.transaction { it.exec("INSERT INTO a VALUES (?)", listOf(1L)); "done" }

        assertEquals("done", answer)
        assertEquals(1L, db.long("SELECT count(*) FROM a"))
    }

    @Test
    fun aFailedTransactionRollsBackAndRethrowsItsError() {
        db.exec("CREATE TABLE a (x)")
        val failure = IllegalStateException("the work failed")

        val thrown = assertFailsWith<IllegalStateException> {
            db.transaction {
                it.exec("INSERT INTO a VALUES (?)", listOf("row"))
                throw failure
            }
        }

        assertSame(failure, thrown)
        assertEquals(0L, db.long("SELECT count(*) FROM a"))
        assertEquals(false, db.inTransaction())
    }
}
