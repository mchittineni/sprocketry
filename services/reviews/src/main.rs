//! Reviews service: shoppers' ratings and reviews of products, kept in PostgreSQL. Anyone can read them;
//! writing one needs a Keycloak access token, which the storefront forwards through Dapr.

mod auth;

use std::{sync::Arc, time::Duration};

use axum::{
    Json, Router,
    extract::{FromRef, FromRequestParts, Path, State},
    http::{StatusCode, request::Parts},
    response::{IntoResponse, Response},
    routing::get,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::{PgPool, postgres::PgPoolOptions};

use crate::auth::{AuthError, Claims, Verifier};

/// Every replica applies the schema on start. One query runs as one transaction, and the advisory lock
/// makes replicas take turns: concurrent CREATE TABLE IF NOT EXISTS on an empty database fails otherwise.
const SCHEMA: &str = concat!(
    "SELECT pg_advisory_xact_lock(hashtext('reviews-schema'));\n",
    include_str!("../schema.sql")
);
const MAX_BODY: usize = 2000;

#[derive(Clone)]
struct AppState {
    db: PgPool,
    verifier: Arc<Verifier>,
    http: reqwest::Client,
    /// Base URL of the Dapr sidecar's HTTP API.
    dapr: String,
}

impl FromRef<AppState> for Arc<Verifier> {
    fn from_ref(state: &AppState) -> Self {
        state.verifier.clone()
    }
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .json()
        .with_current_span(false)
        .init();
    if let Err(err) = run().await {
        tracing::error!(error = %err, "reviews failed");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let db = PgPoolOptions::new()
        .max_connections(10)
        .acquire_timeout(Duration::from_secs(5))
        .connect(&env(
            "DATABASE_URL",
            "postgres://sprocketry:sprocketry@localhost:5432/reviews",
        ))
        .await?;
    apply_schema(&db).await?;

    let verifier = Verifier::new(
        env(
            "OIDC_JWKS_URL",
            "http://localhost:8081/realms/sprocketry/protocol/openid-connect/certs",
        ),
        &env("OIDC_ISSUER", "http://localhost:8081/realms/sprocketry"),
        &env("OIDC_AUDIENCE", "sprocketry-api"),
    );
    let state = AppState {
        db,
        verifier: Arc::new(verifier),
        http: reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()?,
        dapr: format!("http://localhost:{}", env("DAPR_HTTP_PORT", "3500")),
    };

    let addr = format!("0.0.0.0:{}", env("PORT", "8080"));
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    tracing::info!(%addr, "reviews listening");
    axum::serve(listener, routes(state))
        .with_graceful_shutdown(shutdown())
        .await?;
    Ok(())
}

async fn apply_schema<'e>(db: impl sqlx::PgExecutor<'e>) -> Result<(), sqlx::Error> {
    sqlx::raw_sql(SCHEMA).execute(db).await.map(|_| ())
}

fn routes(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(|| async { StatusCode::OK }))
        .route("/readyz", get(ready))
        .route("/products/{sku}/reviews", get(list).post(create))
        .with_state(state)
}

async fn shutdown() {
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .expect("signal handler");
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {},
        _ = term.recv() => {},
    }
}

async fn ready(State(state): State<AppState>) -> StatusCode {
    match sqlx::query("SELECT 1").execute(&state.db).await {
        Ok(_) => StatusCode::OK,
        Err(_) => StatusCode::SERVICE_UNAVAILABLE,
    }
}

#[derive(Debug, Serialize, sqlx::FromRow)]
struct Review {
    id: i64,
    sku: String,
    author: String,
    rating: i16,
    body: String,
    created_at: DateTime<Utc>,
}

#[derive(Serialize)]
struct ReviewList {
    sku: String,
    count: i64,
    /// Mean rating to one decimal place; null when there are no reviews.
    average: Option<f64>,
    reviews: Vec<Review>,
}

async fn list(
    State(state): State<AppState>,
    Path(sku): Path<String>,
) -> Result<Json<ReviewList>, ApiError> {
    let reviews = sqlx::query_as::<_, Review>(
        "SELECT id, sku, author, rating, body, created_at FROM reviews WHERE sku = $1 ORDER BY created_at DESC LIMIT 100",
    )
    .bind(&sku)
    .fetch_all(&state.db)
    .await?;
    let (count, average): (i64, Option<f64>) = sqlx::query_as(
        "SELECT count(*), round(avg(rating), 1)::float8 FROM reviews WHERE sku = $1",
    )
    .bind(&sku)
    .fetch_one(&state.db)
    .await?;
    Ok(Json(ReviewList {
        sku,
        count,
        average,
        reviews,
    }))
}

#[derive(Deserialize)]
struct NewReview {
    rating: i16,
    body: String,
}

async fn create(
    State(state): State<AppState>,
    claims: Claims,
    Path(sku): Path<String>,
    Json(input): Json<NewReview>,
) -> Result<(StatusCode, Json<Review>), ApiError> {
    if !(1..=5).contains(&input.rating) {
        return Err(ApiError::BadRequest("rating must be between 1 and 5"));
    }
    let body = input.body.trim();
    if body.is_empty() || body.chars().count() > MAX_BODY {
        return Err(ApiError::BadRequest("review must be 1 to 2000 characters"));
    }

    // Only products the catalog knows can be reviewed.
    let product = state
        .http
        .get(format!(
            "{}/v1.0/invoke/catalog/method/products/{}",
            state.dapr,
            encode(&sku)
        ))
        .send()
        .await
        .map_err(|e| ApiError::Upstream(e.to_string()))?;
    match product.status() {
        StatusCode::NOT_FOUND => return Err(ApiError::NotFound("unknown product")),
        s if !s.is_success() => return Err(ApiError::Upstream(format!("catalog returned {s}"))),
        _ => {}
    }

    let review = sqlx::query_as::<_, Review>(
        "INSERT INTO reviews (sku, user_id, author, rating, body) VALUES ($1, $2, $3, $4, $5)
         ON CONFLICT (sku, user_id) DO NOTHING
         RETURNING id, sku, author, rating, body, created_at",
    )
    .bind(&sku)
    .bind(&claims.sub)
    .bind(claims.author())
    .bind(input.rating)
    .bind(body)
    .fetch_optional(&state.db)
    .await?
    .ok_or(ApiError::Conflict("you have already reviewed this product"))?;
    Ok((StatusCode::CREATED, Json(review)))
}

/// Path segments are URL-encoded so a SKU can't change which catalog route is called.
fn encode(segment: &str) -> String {
    segment
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// Handlers that take `Claims` only run with a valid bearer token.
impl<S> FromRequestParts<S> for Claims
where
    Arc<Verifier>: FromRef<S>,
    S: Send + Sync,
{
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, Self::Rejection> {
        let token = parts
            .headers
            .get(axum::http::header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer "))
            .ok_or(ApiError::Auth(AuthError::Missing))?;
        Arc::<Verifier>::from_ref(state)
            .verify(token)
            .await
            .map_err(ApiError::Auth)
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ApiError {
    #[error("{0}")]
    Auth(AuthError),
    #[error("{0}")]
    BadRequest(&'static str),
    #[error("{0}")]
    NotFound(&'static str),
    #[error("{0}")]
    Conflict(&'static str),
    #[error("upstream: {0}")]
    Upstream(String),
    #[error("database: {0}")]
    Db(#[from] sqlx::Error),
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let status = match &self {
            ApiError::Auth(AuthError::Keys(_)) => StatusCode::SERVICE_UNAVAILABLE,
            ApiError::Auth(_) => StatusCode::UNAUTHORIZED,
            ApiError::BadRequest(_) => StatusCode::BAD_REQUEST,
            ApiError::NotFound(_) => StatusCode::NOT_FOUND,
            ApiError::Conflict(_) => StatusCode::CONFLICT,
            ApiError::Upstream(_) => StatusCode::BAD_GATEWAY,
            ApiError::Db(_) => StatusCode::INTERNAL_SERVER_ERROR,
        };
        // Details of server-side failures go to the log, not the caller.
        let message = if status.is_server_error() {
            tracing::error!(error = %self, "request failed");
            "internal error".to_owned()
        } else {
            self.to_string()
        };
        (status, message).into_response()
    }
}

fn env(key: &str, fallback: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| fallback.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::tests::{token, verifier};
    use axum::{body::Body, http::Request};
    use serde_json::{Value, json};
    use tower::ServiceExt;

    /// A stand-in for the Dapr sidecar: the catalog knows RB-001 and RB-002 only.
    async fn fake_dapr() -> String {
        let app = Router::new().route(
            "/v1.0/invoke/catalog/method/products/{sku}",
            get(|Path(sku): Path<String>| async move {
                if sku == "RB-001" || sku == "RB-002" {
                    StatusCode::OK
                } else {
                    StatusCode::NOT_FOUND
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        format!("http://{addr}")
    }

    async fn state(db: PgPool) -> AppState {
        AppState {
            db,
            verifier: Arc::new(verifier()),
            http: reqwest::Client::new(),
            dapr: fake_dapr().await,
        }
    }

    /// A pool that never connects, for tests that must not reach the database.
    fn no_db() -> PgPool {
        PgPoolOptions::new()
            .connect_lazy("postgres://nobody@127.0.0.1:1/none")
            .unwrap()
    }

    /// Database tests share one database and wipe it, so they take turns.
    static DB_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    /// A freshly migrated database, or None to skip: the tests wipe it, so it must be disposable.
    async fn test_db() -> Option<(tokio::sync::MutexGuard<'static, ()>, PgPool)> {
        // CI always provides a database, so a missing one there is a broken pipeline, not a reason to pass.
        let url = match std::env::var("TEST_DATABASE_URL") {
            Ok(url) => url,
            Err(_) if std::env::var_os("CI").is_some() => panic!("TEST_DATABASE_URL not set in CI"),
            Err(_) => return None,
        };
        let guard = DB_LOCK.lock().await;
        let db = PgPool::connect(&url).await.unwrap();
        sqlx::raw_sql("DROP TABLE IF EXISTS reviews")
            .execute(&db)
            .await
            .unwrap();
        apply_schema(&db).await.unwrap();
        Some((guard, db))
    }

    async fn send(
        app: &Router,
        method: &str,
        uri: &str,
        bearer: Option<&str>,
        body: Value,
    ) -> (StatusCode, Value) {
        let mut req = Request::builder()
            .method(method)
            .uri(uri)
            .header("content-type", "application/json");
        if let Some(t) = bearer {
            req = req.header("authorization", format!("Bearer {t}"));
        }
        let resp = app
            .clone()
            .oneshot(req.body(Body::from(body.to_string())).unwrap())
            .await
            .unwrap();
        let status = resp.status();
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        (
            status,
            serde_json::from_slice(&bytes)
                .unwrap_or(Value::String(String::from_utf8_lossy(&bytes).into())),
        )
    }

    #[tokio::test]
    async fn writing_needs_a_valid_token() {
        let app = routes(state(no_db()).await);
        let review = json!({ "rating": 5, "body": "Great" });
        let (status, _) = send(
            &app,
            "POST",
            "/products/RB-001/reviews",
            None,
            review.clone(),
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        let bad = token(json!({ "aud": "someone-else" }));
        let (status, _) = send(&app, "POST", "/products/RB-001/reviews", Some(&bad), review).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn invalid_reviews_and_unknown_products_are_rejected() {
        let app = routes(state(no_db()).await);
        let t = token(json!({}));
        for (body, want) in [
            (json!({ "rating": 0, "body": "x" }), StatusCode::BAD_REQUEST),
            (json!({ "rating": 6, "body": "x" }), StatusCode::BAD_REQUEST),
            (
                json!({ "rating": 3, "body": "   " }),
                StatusCode::BAD_REQUEST,
            ),
            (
                json!({ "rating": 3, "body": "x".repeat(MAX_BODY + 1) }),
                StatusCode::BAD_REQUEST,
            ),
        ] {
            assert_eq!(
                send(&app, "POST", "/products/RB-001/reviews", Some(&t), body)
                    .await
                    .0,
                want
            );
        }
        let (status, _) = send(
            &app,
            "POST",
            "/products/NOPE/reviews",
            Some(&t),
            json!({ "rating": 3, "body": "x" }),
        )
        .await;
        assert_eq!(status, StatusCode::NOT_FOUND);
    }

    #[test]
    fn sku_is_encoded_as_one_path_segment() {
        assert_eq!(encode("RB-001"), "RB-001");
        assert_eq!(encode("../../state/x"), "..%2F..%2Fstate%2Fx");
    }

    #[tokio::test]
    async fn reviews_are_stored_once_per_shopper_and_averaged() {
        let Some((_guard, db)) = test_db().await else {
            return eprintln!("TEST_DATABASE_URL not set; skipping");
        };
        let app = routes(state(db).await);
        let ada = token(json!({}));
        let bob = token(json!({ "sub": "user-2", "name": "Bob" }));

        let (status, body) = send(
            &app,
            "POST",
            "/products/RB-001/reviews",
            Some(&ada),
            json!({ "rating": 5, "body": " Lifts anything " }),
        )
        .await;
        assert_eq!(status, StatusCode::CREATED);
        assert_eq!(body["author"], "Ada Lovelace");
        assert_eq!(body["body"], "Lifts anything");

        let (status, _) = send(
            &app,
            "POST",
            "/products/RB-001/reviews",
            Some(&ada),
            json!({ "rating": 1, "body": "again" }),
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT);

        send(
            &app,
            "POST",
            "/products/RB-001/reviews",
            Some(&bob),
            json!({ "rating": 4, "body": "Solid" }),
        )
        .await;
        let (status, list) = send(&app, "GET", "/products/RB-001/reviews", None, Value::Null).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(list["count"], 2);
        assert_eq!(list["average"], 4.5);
        assert_eq!(list["reviews"][0]["author"], "Bob");

        let (_, empty) = send(&app, "GET", "/products/RB-002/reviews", None, Value::Null).await;
        assert_eq!(empty["count"], 0);
        assert_eq!(empty["average"], Value::Null);
    }

    #[tokio::test]
    async fn concurrent_schema_application_succeeds() {
        let Some((_guard, db)) = test_db().await else {
            return eprintln!("TEST_DATABASE_URL not set; skipping");
        };
        sqlx::raw_sql("DROP TABLE reviews")
            .execute(&db)
            .await
            .unwrap();
        // Open every connection first and start together, as replicas booting at once would.
        let barrier = Arc::new(tokio::sync::Barrier::new(4));
        let mut runs = Vec::new();
        for _ in 0..4 {
            let mut conn = db.acquire().await.unwrap();
            let barrier = barrier.clone();
            runs.push(tokio::spawn(async move {
                barrier.wait().await;
                apply_schema(&mut *conn).await
            }));
        }
        for run in runs {
            run.await.unwrap().unwrap();
        }
    }
}
