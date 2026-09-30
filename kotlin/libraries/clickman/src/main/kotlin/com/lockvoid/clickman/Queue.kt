package com.lockvoid.clickman

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.SQLiteDriver
import java.io.Closeable
import java.io.File
import java.nio.file.Files
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * The device queue: one SQLite file in the format of protocol/queue.sql. Any
 * thread may call; the lock gives the connection one transaction at a time.
 */
internal class Queue private constructor(connection: SQLiteConnection) : Closeable {
    private sealed interface State {
        class Open(val connection: SQLiteConnection) : State

        data object Closed : State
    }

    private val lock = ReentrantLock()
    private var state: State = State.Open(connection)

    fun <T> transaction(work: (QueueTransaction) -> T): T = lock.withLock {
        when (val current = state) {
            is State.Open -> current.connection.transaction { work(QueueTransaction(it)) }
            State.Closed -> throw ClickManException("ClickMan is closed")
        }
    }

    override fun close() = lock.withLock {
        when (val current = state) {
            is State.Open -> {
                state = State.Closed
                current.connection.close()
            }
            State.Closed -> Unit
        }
    }

    companion object {
        /** Opens [storage], creating it or adopting a store of the 0.1 Rust core; a store of a later format is refused. */
        fun open(storage: File, driver: SQLiteDriver): Queue {
            Files.createDirectories(storage.absoluteFile.parentFile.toPath())
            val connection = driver.open(storage.path)
            try {
                connection.exec("PRAGMA journal_mode = WAL")
                connection.transaction { migrate(it, storage) }
            } catch (error: Throwable) {
                close(connection, error)
                throw error
            }
            return Queue(connection)
        }

        private fun migrate(db: SQLiteConnection, storage: File) {
            val format = db.long("PRAGMA user_version")
            if (format > QueueSchema.FORMAT) {
                throw ClickManException("${storage.path} is format $format, written by a newer ClickMan")
            }
            if (format == 0L) create(db)
            db.exec("PRAGMA user_version = ${QueueSchema.FORMAT}")
        }

        private fun create(db: SQLiteConnection) {
            sqlStatements(QueueSchema.create).forEach { db.exec(it) }
            if (db.long("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'state'") > 0) {
                sqlStatements(QueueSchema.upgrade).forEach { db.exec(it) }
            }
        }

        private fun close(connection: SQLiteConnection, cause: Throwable) {
            try {
                connection.close()
            } catch (error: Throwable) {
                cause.addSuppressed(error)
            }
        }
    }
}
