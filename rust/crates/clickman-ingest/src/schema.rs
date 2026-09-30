use anyhow::bail;

use crate::Database;

const REQUIRED_TABLES: &[&str] = &["clickman_events", "clickman_settings"];

/// Fails fast, naming the missing table, when the host has not run the
/// ClickMan migrations against the database the server points at.
pub async fn verify_schema(database: &Database) -> anyhow::Result<()> {
    let missing = database.missing_tables(REQUIRED_TABLES).await?;

    if !missing.is_empty() {
        bail!(
            "the ClickMan schema is missing {}; run the host application's ClickMan migrations",
            missing.join(", ")
        );
    }
    Ok(())
}
