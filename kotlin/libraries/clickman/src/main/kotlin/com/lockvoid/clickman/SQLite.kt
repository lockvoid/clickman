package com.lockvoid.clickman

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.SQLiteStatement

/** `androidx.sqlite` prepares one statement at a time; comments may contain `;`. */
internal fun sqlStatements(script: String): List<String> =
    script.lines().joinToString("\n") { it.substringBefore("--") }
        .split(';').filter { it.isNotBlank() }

/** ONE statement: `androidx.sqlite` prepares to the first `;` and silently drops the rest. */
internal fun SQLiteConnection.exec(sql: String, arguments: List<Any?> = emptyList()) {
    prepare(sql).use { statement ->
        statement.bindAll(arguments)
        statement.step()
    }
}

internal fun <T> SQLiteConnection.query(
    sql: String,
    arguments: List<Any?> = emptyList(),
    map: (SQLiteStatement) -> T,
): List<T> = prepare(sql).use { statement ->
    statement.bindAll(arguments)
    val rows = mutableListOf<T>()
    while (statement.step()) rows.add(map(statement))
    rows
}

/** The row a query always answers, such as an aggregate's or the identity's. */
internal fun <T> SQLiteConnection.single(sql: String, map: (SQLiteStatement) -> T): T = query(sql, map = map).single()

internal fun SQLiteConnection.long(sql: String): Long = single(sql) { it.getLong(0) }

internal fun SQLiteStatement.textOrNull(index: Int): String? = if (isNull(index)) null else getText(index)

/** `BEGIN IMMEDIATE` … `COMMIT`; a failure rolls the work back and is rethrown. */
internal fun <T> SQLiteConnection.transaction(work: (SQLiteConnection) -> T): T {
    exec("BEGIN IMMEDIATE")
    try {
        return work(this).also { exec("COMMIT") }
    } catch (error: Throwable) {
        rollBack(error)
        throw error
    }
}

/** SQLite rolls some failures back itself, so the connection is asked; a failed rollback rides on its cause. */
private fun SQLiteConnection.rollBack(cause: Throwable) {
    try {
        if (inTransaction()) exec("ROLLBACK")
    } catch (error: Throwable) {
        cause.addSuppressed(error)
    }
}

private fun SQLiteStatement.bindAll(arguments: List<Any?>) {
    arguments.forEachIndexed { index, argument ->
        when (argument) {
            null -> bindNull(index + 1)
            is String -> bindText(index + 1, argument)
            is Long -> bindLong(index + 1, argument)
            is Int -> bindLong(index + 1, argument.toLong())
            else -> throw IllegalArgumentException("cannot bind ${argument::class}")
        }
    }
}
