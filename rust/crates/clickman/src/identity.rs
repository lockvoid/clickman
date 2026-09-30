use rusqlite::{Connection, Transaction};
use serde_json::{Map, Value};

use crate::error::{Error, Result};
use crate::event::is_valid_text;

pub(crate) const MAX_EXTERNAL_ID_CHARS: usize = 256;

/// Whom later events are about: their `externalId` and the traits their context carries.
pub(crate) struct Actor {
    pub(crate) external_id: String,
    pub(crate) traits: Map<String, Value>,
}

pub(crate) fn actor(connection: &Connection) -> Result<Actor> {
    let (external_id, traits): (String, String) = connection.query_row(
        "SELECT external_id, traits FROM identity WHERE id = 1",
        [],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    let traits = serde_json::from_str(&traits).map_err(Error::StoredTraits)?;
    Ok(Actor {
        external_id,
        traits,
    })
}

pub(crate) fn identify(transaction: &Transaction, external_id: &str) -> Result<()> {
    if !is_valid_text(external_id, MAX_EXTERNAL_ID_CHARS) {
        return Err(Error::InvalidExternalId);
    }
    transaction.execute(
        "UPDATE identity SET external_id = ?1 WHERE id = 1",
        [external_id],
    )?;
    Ok(())
}

/// Makes later events anonymous and forgets the traits.
pub(crate) fn reset(transaction: &Transaction) -> Result<()> {
    transaction.execute(
        "UPDATE identity SET external_id = '*', traits = '{}' WHERE id = 1",
        [],
    )?;
    Ok(())
}

pub(crate) fn set_traits(transaction: &Transaction, changes: Map<String, Value>) -> Result<()> {
    let traits = merge(actor(transaction)?.traits, changes);
    transaction.execute(
        "UPDATE identity SET traits = ?1 WHERE id = 1",
        [Value::Object(traits).to_string()],
    )?;
    Ok(())
}

/// Traits merged key by key: a null removes a trait, any other value replaces it whole (traits.json).
pub(crate) fn merge(
    mut traits: Map<String, Value>,
    changes: Map<String, Value>,
) -> Map<String, Value> {
    traits.extend(changes);
    traits.retain(|_, value| !value.is_null());
    traits
}
