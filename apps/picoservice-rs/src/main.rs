use axum::{routing::get, Json, Router};
use axum_prometheus::PrometheusMetricLayer;
use serde_json::{json, Value};
use std::time::Duration;
use tracing_subscriber::FmtSubscriber;

#[tokio::main]
async fn main() {
    let subscriber = FmtSubscriber::builder()
        .with_max_level(tracing::Level::INFO)
        .finish();
    tracing::subscriber::set_global_default(subscriber).unwrap();

    let (prometheus_layer, metric_handle) = PrometheusMetricLayer::pair();
    let app = Router::new()
        .route("/", get(index_handler))
        .route("/slow", get(slow_handler))
        .route("/health", get(health_handler))
        .route("/metrics", get(|| async move { metric_handle.render() }))
        .layer(prometheus_layer);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000").await.unwrap();

    axum::serve(listener, app).await.unwrap();
}

async fn index_handler() -> &'static str {
    "Greetings!"
}

async fn slow_handler() -> &'static str {
    tokio::time::sleep(Duration::from_secs(1)).await;
    "Whats happening!?"
}

async fn health_handler() -> Json<Value> {
    let version = env!("CARGO_PKG_VERSION");

    Json(json!({
        "app": "picoservice-rs",
        "version": version,
        "status": "ok",
    }))
}
