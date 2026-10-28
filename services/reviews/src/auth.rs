//! Checks Keycloak access tokens. Keycloak signs them with RS256 and publishes its public keys as a JSON
//! Web Key Set; keys are cached and refetched when a token names a key we haven't seen (Keycloak rotates).

use std::{
    collections::HashMap,
    time::{Duration, Instant},
};

use jsonwebtoken::{Algorithm, DecodingKey, Validation, decode, decode_header, jwk::JwkSet};
use serde::Deserialize;
use tokio::sync::RwLock;

/// Refetch the key set at most this often, so tokens naming unknown keys can't hammer Keycloak.
const MIN_REFRESH: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Deserialize)]
pub struct Claims {
    pub sub: String,
    pub name: Option<String>,
    pub preferred_username: Option<String>,
}

impl Claims {
    /// The name shown on a review.
    pub fn author(&self) -> String {
        self.name
            .clone()
            .or_else(|| self.preferred_username.clone())
            .filter(|n| !n.trim().is_empty())
            .unwrap_or_else(|| "Anonymous".to_owned())
    }
}

#[derive(Debug, thiserror::Error)]
pub enum AuthError {
    #[error("missing bearer token")]
    Missing,
    #[error("invalid token: {0}")]
    Invalid(String),
    #[error("signing keys unavailable: {0}")]
    Keys(String),
}

struct Keys {
    by_kid: HashMap<String, DecodingKey>,
    fetched: Option<Instant>,
}

pub struct Verifier {
    jwks_url: Option<String>,
    http: reqwest::Client,
    validation: Validation,
    keys: RwLock<Keys>,
}

impl Verifier {
    /// `issuer` is the public URL tokens are issued under, which can differ from `jwks_url`, the
    /// address this service reaches Keycloak at.
    pub fn new(jwks_url: String, issuer: &str, audience: &str) -> Self {
        Self::build(Some(jwks_url), issuer, audience, HashMap::new())
    }

    /// A verifier with a fixed key set and no fetching, for tests.
    #[cfg(test)]
    pub fn with_keys(set: &JwkSet, issuer: &str, audience: &str) -> Self {
        Self::build(None, issuer, audience, index(set))
    }

    fn build(
        jwks_url: Option<String>,
        issuer: &str,
        audience: &str,
        by_kid: HashMap<String, DecodingKey>,
    ) -> Self {
        let mut validation = Validation::new(Algorithm::RS256);
        validation.set_issuer(&[issuer]);
        validation.set_audience(&[audience]);
        validation.set_required_spec_claims(&["exp", "iss", "aud", "sub"]);
        validation.leeway = 30;
        Self {
            jwks_url,
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(5))
                .build()
                .expect("http client"),
            validation,
            keys: RwLock::new(Keys {
                by_kid,
                fetched: None,
            }),
        }
    }

    pub async fn verify(&self, token: &str) -> Result<Claims, AuthError> {
        let header = decode_header(token).map_err(|e| AuthError::Invalid(e.to_string()))?;
        if header.alg != Algorithm::RS256 {
            return Err(AuthError::Invalid(format!(
                "unexpected algorithm {:?}",
                header.alg
            )));
        }
        let kid = header
            .kid
            .ok_or_else(|| AuthError::Invalid("token has no key id".into()))?;
        let key = self.key(&kid).await?;
        decode::<Claims>(token, &key, &self.validation)
            .map(|data| data.claims)
            .map_err(|e| AuthError::Invalid(e.to_string()))
    }

    async fn key(&self, kid: &str) -> Result<DecodingKey, AuthError> {
        if let Some(key) = self.keys.read().await.by_kid.get(kid) {
            return Ok(key.clone());
        }
        let Some(url) = &self.jwks_url else {
            return Err(AuthError::Invalid("unknown key id".into()));
        };
        let mut keys = self.keys.write().await;
        // Another request may have refreshed while this one waited for the lock.
        if let Some(key) = keys.by_kid.get(kid) {
            return Ok(key.clone());
        }
        if keys.fetched.is_some_and(|at| at.elapsed() < MIN_REFRESH) {
            return Err(AuthError::Invalid("unknown key id".into()));
        }
        let set: JwkSet = self
            .http
            .get(url)
            .send()
            .await
            .and_then(reqwest::Response::error_for_status)
            .map_err(|e| AuthError::Keys(e.to_string()))?
            .json()
            .await
            .map_err(|e| AuthError::Keys(e.to_string()))?;
        keys.by_kid = index(&set);
        keys.fetched = Some(Instant::now());
        keys.by_kid
            .get(kid)
            .cloned()
            .ok_or_else(|| AuthError::Invalid("unknown key id".into()))
    }
}

/// RSA signing keys by key id. Keycloak's set also holds encryption keys, which are skipped.
fn index(set: &JwkSet) -> HashMap<String, DecodingKey> {
    set.keys
        .iter()
        .filter(|jwk| {
            !matches!(
                jwk.common.public_key_use,
                Some(jsonwebtoken::jwk::PublicKeyUse::Encryption)
            )
        })
        .filter_map(|jwk| Some((jwk.common.key_id.clone()?, DecodingKey::from_jwk(jwk).ok()?)))
        .collect()
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use jsonwebtoken::{EncodingKey, Header, encode};
    use serde_json::json;

    pub const ISSUER: &str = "http://localhost:8081/realms/sprocketry";
    pub const AUDIENCE: &str = "sprocketry-api";
    const KID: &str = "test-key";
    // Public half of tests/fixtures/test-signing-key.pem.
    const N: &str = "yEaCfGCauxRmRKbxMyj1nrzSwUk-WDXNKN65BbwhzYXDAsE6fXQKc-DxGNX45laDhK5XJ-2btOU-oUxYduaOe0js-aC0RRHiqVZ3ZsRhBRr6x06lYen9_P6iakNy8MaQV-BhGtWzPQBr-NHROL4ZB_pMwdebbHWdLxoYPGznMMY8My9roY_0Myc1Rl232292hRqzmXMd5707BbaB5IglsQfHKnQdCLWd58FpOsGMUif9P5tuZ_syF_TuC8rOFNvVKLpjqpzmJcrGjvEhxqixO9VlZSLzfTcfyQ-mQlnpKC0YlblgBFMuChIv7lV6vSVHyvT4GpsYWpAtWBgJoyDOxw";

    pub fn verifier() -> Verifier {
        let set: JwkSet = serde_json::from_value(json!({
            "keys": [{ "kty": "RSA", "kid": KID, "use": "sig", "alg": "RS256", "n": N, "e": "AQAB" }]
        }))
        .unwrap();
        Verifier::with_keys(&set, ISSUER, AUDIENCE)
    }

    /// A token signed with the test key; `overrides` replaces or adds claims.
    pub fn token(overrides: serde_json::Value) -> String {
        let pem = include_str!("../tests/fixtures/test-signing-key.pem");
        let pem = &pem[pem.find("-----BEGIN").unwrap()..];
        let now = chrono::Utc::now().timestamp();
        let mut claims = json!({
            "sub": "user-1", "iss": ISSUER, "aud": [AUDIENCE, "account"], "exp": now + 300, "iat": now,
            "name": "Ada Lovelace", "preferred_username": "ada",
        });
        claims
            .as_object_mut()
            .unwrap()
            .extend(overrides.as_object().unwrap().clone());
        let mut header = Header::new(Algorithm::RS256);
        header.kid = Some(KID.into());
        encode(
            &header,
            &claims,
            &EncodingKey::from_rsa_pem(pem.as_bytes()).unwrap(),
        )
        .unwrap()
    }

    #[tokio::test]
    async fn accepts_a_valid_token() {
        let claims = verifier().verify(&token(json!({}))).await.unwrap();
        assert_eq!(claims.sub, "user-1");
        assert_eq!(claims.author(), "Ada Lovelace");
    }

    #[tokio::test]
    async fn rejects_wrong_audience_issuer_or_expiry() {
        let v = verifier();
        let past = chrono::Utc::now().timestamp() - 3600;
        for (case, overrides) in [
            ("audience", json!({ "aud": "account" })),
            (
                "issuer",
                json!({ "iss": "http://evil.example/realms/sprocketry" }),
            ),
            ("expired", json!({ "exp": past })),
        ] {
            assert!(
                v.verify(&token(overrides)).await.is_err(),
                "{case} should be rejected"
            );
        }
    }

    #[tokio::test]
    async fn rejects_tampering_and_other_algorithms() {
        let v = verifier();
        let good = token(json!({}));
        // Swap in a payload the key never signed.
        let mut parts: Vec<&str> = good.split('.').collect();
        let forged = token(json!({ "sub": "someone-else" }));
        parts[1] = forged.split('.').nth(1).unwrap();
        assert!(v.verify(&parts.join(".")).await.is_err());

        // A shared-secret token must not be accepted in place of an RSA one.
        let hs = encode(
            &Header::new(Algorithm::HS256),
            &json!({ "sub": "x" }),
            &EncodingKey::from_secret(b"k"),
        )
        .unwrap();
        assert!(v.verify(&hs).await.is_err());
    }

    #[tokio::test]
    async fn falls_back_to_username_then_anonymous() {
        let v = verifier();
        let claims = v.verify(&token(json!({ "name": null }))).await.unwrap();
        assert_eq!(claims.author(), "ada");
        let claims = v
            .verify(&token(json!({ "name": null, "preferred_username": null })))
            .await
            .unwrap();
        assert_eq!(claims.author(), "Anonymous");
    }
}
