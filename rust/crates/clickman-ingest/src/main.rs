use std::env;
use std::net::SocketAddr;
use std::time::Duration;

use anyhow::{Context, Result};
use clickman_ingest::{AppState, Database, SettingsCell, router, verify_schema};
use tokio::io::AsyncReadExt;
use tokio::sync::watch;
use tracing::{error, info, warn};

const DEFAULT_BIND: &str = "127.0.0.1:4130";
const DEFAULT_POOL_SIZE: u32 = 4;
const DEFAULT_SETTINGS_REFRESH_SECONDS: u64 = 30;
const ORPHAN_HARD_EXIT_TIMEOUT: Duration = Duration::from_secs(10);

struct Configuration {
    bind: SocketAddr,
    database_url: String,
    pool_size: u32,
    settings_refresh: Duration,
}

impl Configuration {
    fn from_env() -> Result<Self> {
        Ok(Self {
            bind: env::var("CLICKMAN_INGEST_BIND")
                .unwrap_or_else(|_| DEFAULT_BIND.to_owned())
                .parse()
                .context("CLICKMAN_INGEST_BIND must be host:port")?,
            database_url: env::var("DATABASE_URL")
                .context("DATABASE_URL is required by clickman-ingest")?,
            pool_size: number("CLICKMAN_INGEST_DATABASE_POOL", DEFAULT_POOL_SIZE)?,
            settings_refresh: Duration::from_secs(number(
                "CLICKMAN_INGEST_SETTINGS_REFRESH",
                DEFAULT_SETTINGS_REFRESH_SECONDS,
            )?),
        })
    }
}

fn number<T: std::str::FromStr>(name: &str, default: T) -> Result<T> {
    match env::var(name) {
        Ok(value) => value
            .parse()
            .map_err(|_| anyhow::anyhow!("{name} must be a positive number")),
        Err(_) => Ok(default),
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .json()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "clickman_ingest=info".into()),
        )
        .init();

    let configuration = Configuration::from_env()?;
    let database = Database::connect(&configuration.database_url, configuration.pool_size).await?;

    verify_schema(&database).await?;
    let settings = SettingsCell::load(&database)
        .await
        .context("load the published ingest settings")?;

    let (shutdown, _) = watch::channel(false);
    let refresher = spawn_settings_refresh(
        database.clone(),
        settings.clone(),
        configuration.settings_refresh,
        shutdown.subscribe(),
    );

    let listener = tokio::net::TcpListener::bind(configuration.bind)
        .await
        .with_context(|| format!("bind clickman-ingest to {}", configuration.bind))?;
    info!(address = %configuration.bind, "clickman-ingest listening");

    axum::serve(
        listener,
        router(AppState::new(database.clone(), settings))
            .into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown_signal(shutdown))
    .await
    .context("serve clickman-ingest")?;

    refresher.abort();
    database.close().await;
    info!("clickman-ingest stopped");
    Ok(())
}

fn spawn_settings_refresh(
    database: Database,
    settings: SettingsCell,
    every: Duration,
    mut shutdown: watch::Receiver<bool>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(every);
        ticker.tick().await;
        loop {
            tokio::select! {
                _ = ticker.tick() => {
                    if let Err(refresh_error) = settings.reload(&database).await {
                        warn!(error = %refresh_error, "could not refresh the ingest settings; keeping the previous ones");
                    }
                }
                _ = shutdown.changed() => break,
            }
        }
    })
}

async fn shutdown_signal(shutdown: watch::Sender<bool>) {
    let interrupt = async {
        if let Err(signal_error) = tokio::signal::ctrl_c().await {
            error!(error = %signal_error, "could not install the Ctrl-C handler");
        }
    };

    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut signal) => {
                signal.recv().await;
            }
            Err(signal_error) => {
                error!(error = %signal_error, "could not install the SIGTERM handler")
            }
        }
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    // The dev supervisor hands us its stdin as a lifeline: when the supervisor
    // dies, even by SIGKILL, the pipe closes and the server frees its port.
    let supervisor_lifeline = async {
        if env::var("CLICKMAN_INGEST_SUPERVISED").as_deref() == Ok("1") {
            let mut stdin = tokio::io::stdin();
            let mut sink = [0u8; 1024];
            while let Ok(read) = stdin.read(&mut sink).await {
                if read == 0 {
                    break;
                }
            }
            warn!("supervisor lifeline closed; shutting down");
            tokio::spawn(async {
                tokio::time::sleep(ORPHAN_HARD_EXIT_TIMEOUT).await;
                error!("the orphaned server did not stop in time; exiting");
                std::process::exit(1);
            });
        } else {
            std::future::pending::<()>().await;
        }
    };

    tokio::select! {
        _ = interrupt => {},
        _ = terminate => {},
        _ = supervisor_lifeline => {},
    }

    info!("shutdown signal received");
    let _ = shutdown.send(true);
}
