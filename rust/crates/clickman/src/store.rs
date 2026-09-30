use std::path::Path;

use parking_lot::Mutex;
use rusqlite::{Connection, Transaction, TransactionBehavior};

use crate::error::{Error, Result};
use crate::queue_schema::{CREATE, FORMAT, UPGRADE};

/// The queue's SQLite file, behind one connection.
pub(crate) struct Store {
    connection: Mutex<Connection>,
}

impl Store {
    /// Opens the store at `path`: a new one is created, a format 0 store of the
    /// 0.1 Rust core adopted, and one of a later format refused.
    pub(crate) fn open(path: &Path) -> Result<Self> {
        create_parent(path)?;
        let mut connection = Connection::open(path)?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        migrate(&mut connection)?;
        Ok(Self {
            connection: Mutex::new(connection),
        })
    }

    /// Runs `work` in one IMMEDIATE transaction, committed only when it succeeds.
    pub(crate) fn write<T>(&self, work: impl FnOnce(&Transaction) -> Result<T>) -> Result<T> {
        let mut connection = self.connection.lock();
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let value = work(&transaction)?;
        transaction.commit()?;
        Ok(value)
    }

    pub(crate) fn read<T>(&self, work: impl FnOnce(&Connection) -> Result<T>) -> Result<T> {
        work(&self.connection.lock())
    }
}

/// A count bound into SQL; a count past `i64::MAX` is no limit at all.
pub(crate) fn sql_count(count: usize) -> i64 {
    count.min(i64::MAX as usize) as i64
}

fn create_parent(path: &Path) -> Result<()> {
    let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    else {
        return Ok(());
    };
    std::fs::create_dir_all(parent).map_err(|source| Error::StoreDirectory {
        path: parent.to_owned(),
        source,
    })
}

fn migrate(connection: &mut Connection) -> Result<()> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    match transaction.pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))? {
        0 => create(&transaction)?,
        FORMAT => {}
        format if format > FORMAT => return Err(Error::NewerStore { format }),
        format => return Err(Error::UnknownStore { format }),
    }
    transaction.commit()?;
    Ok(())
}

fn create(transaction: &Transaction) -> Result<()> {
    transaction.execute_batch(CREATE)?;
    if has_table(transaction, "state")? {
        transaction.execute_batch(UPGRADE)?;
    }
    transaction.pragma_update(None, "user_version", FORMAT)?;
    Ok(())
}

fn has_table(connection: &Connection, name: &str) -> Result<bool> {
    Ok(connection.query_row(
        "SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1)",
        [name],
        |row| row.get(0),
    )?)
}
