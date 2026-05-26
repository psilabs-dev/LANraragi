//! Auth tower layer.
//!
//! Implements the middleware algorithm from design.md "Auth (resolved)" rule 10:
//!  1. OPTIONS → always pass (CORS preflight; mirrors Perl Login.pm:61).
//!  2. (method, MatchedPath) not in secured set → pass (anonymous route).
//!  3. Secured + api_key_hash is None → 401 (read-only mode).
//!  4. Extract candidate plaintext from `Authorization: Bearer <base64>` or
//!     `?key=<plaintext>` query param (OPDS fallback; Perl Utils/Login.pm:22-23).
//!  5. Cache hit → pass.
//!  6. Argon2 verify on Rayon. Success → cache + pass. Failure → 401.
//!
//! 401 responses use `constants::UNAUTHORIZED_BODY` directly — NOT `ApiError`.
//! The `ApiError` envelope (`{operation, success, error}`) is wrong for this
//! contract (design rule 13).

use std::sync::Arc;

use axum::{
    extract::{MatchedPath, Request, State},
    http::{Method, StatusCode, header},
    middleware::Next,
    response::{IntoResponse, Response},
};
use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use percent_encoding::percent_decode_str;

use crate::{constants::UNAUTHORIZED_BODY, error::ApiError, state::AppState};

/// Argon2 verify errors. Only used inside the Rayon closure; never surfaced
/// to callers directly.
enum VerifyError {
    HashParse,
    Mismatch,
    Cancelled,
}

/// Runs Argon2id verification on the Rayon pool. Returns `Ok(())` on success.
///
/// port of LANraragi::Utils::Login::is_logged_in_api (verify path)
/// commit hash: f7249980
async fn verify_on_rayon(
    rayon: Arc<rayon::ThreadPool>,
    plaintext: String,
    stored_hash: String,
) -> Result<(), VerifyError> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    rayon.spawn(move || {
        let result = verify_argon2(&plaintext, &stored_hash);
        let _ = tx.send(result);
    });
    rx.await.unwrap_or(Err(VerifyError::Cancelled))
}

/// Pure synchronous Argon2 verify; runs on Rayon.
fn verify_argon2(plaintext: &str, stored_hash: &str) -> Result<(), VerifyError> {
    use argon2::{Argon2, PasswordVerifier, password_hash::PasswordHash};

    let parsed = PasswordHash::new(stored_hash).map_err(|_| VerifyError::HashParse)?;
    Argon2::default()
        .verify_password(plaintext.as_bytes(), &parsed)
        .map_err(|_| VerifyError::Mismatch)
}

fn unauthorized() -> Response {
    (
        StatusCode::UNAUTHORIZED,
        [(header::CONTENT_TYPE, "application/json")],
        UNAUTHORIZED_BODY,
    )
        .into_response()
}

/// Extracts bearer plaintext from the `Authorization` header or the `?key=`
/// query param (OPDS fallback). Returns `None` when neither is present or the
/// base64 is malformed (design contract: malformed base64 → 401, not 400).
///
/// port of LANraragi::Utils::Login::is_logged_in_api (extract path)
/// commit hash: f7249980
fn extract_plaintext(req: &Request) -> Option<String> {
    // Primary: Authorization: Bearer <base64(plaintext)>
    if let Some(value) = req.headers().get(header::AUTHORIZATION) {
        if let Ok(s) = value.to_str() {
            if let Some(encoded) = s.strip_prefix("Bearer ") {
                return B64.decode(encoded.trim()).ok().and_then(|b| String::from_utf8(b).ok());
            }
        }
    }

    // Fallback: ?key=<plaintext> (OPDS; Perl Utils/Login.pm:22-23)
    if let Some(query) = req.uri().query() {
        for pair in query.split('&') {
            if let Some((k, v)) = pair.split_once('=') {
                if k == "key" && !v.is_empty() {
                    return percent_decode_str(v).decode_utf8().ok().map(|s| s.into_owned());
                }
            }
        }
    }

    None
}

/// Tower middleware function. Mount via `axum::middleware::from_fn_with_state`.
pub async fn layer(State(state): State<AppState>, req: Request, next: Next) -> Response {
    // 1. OPTIONS always passes (CORS preflight).
    if req.method() == Method::OPTIONS {
        return next.run(req).await;
    }

    // 2. Anonymous route check.
    let matched = req.extensions().get::<MatchedPath>().map(|m| m.as_str().to_string());
    let Some(path) = matched else {
        // No matched path means no registered handler; let axum 404.
        return next.run(req).await;
    };
    let key = (req.method().clone(), path);
    if !state.secured.contains(&key) {
        return next.run(req).await;
    }

    // 3. Secured + read-only mode.
    let Some(ref stored_hash) = state.api_key_hash else {
        return unauthorized();
    };

    // 4. Extract candidate plaintext.
    let Some(plaintext) = extract_plaintext(&req) else {
        return unauthorized();
    };

    // 5. Cache hit. `Some(true)` → previously validated, pass; `Some(false)` →
    //    previously invalid, 401 without re-verify; `None` → must run Argon2.
    match state.verify_cache.get(&plaintext).await {
        Some(true) => return next.run(req).await,
        Some(false) => return unauthorized(),
        None => {}
    }

    // 6. Argon2 verify on Rayon.
    let stored = stored_hash.to_string();
    match verify_on_rayon(state.rayon.clone(), plaintext.clone(), stored).await {
        Ok(()) => {
            state.verify_cache.insert(plaintext, true).await;
            next.run(req).await
        }
        Err(VerifyError::HashParse) => {
            tracing::error!("lrr_api_key row contains an unparseable Argon2 PHC string");
            // 500: corrupted DB row, not an auth failure. ApiError envelope is
            // fine here — the 401-must-not-use-ApiError rule (design rule 13)
            // applies only to the auth-failure path, not to server errors.
            ApiError::internal("hashParse", "lrr_api_key row contains an unparseable Argon2 PHC string").into_response()
        }
        // Cache the mismatch to avoid re-paying Argon2 on repeated wrong-key
        // requests. Cancelled (Rayon panic) is NOT cached: the outcome is
        // indeterminate, not "invalid".
        Err(VerifyError::Mismatch) => {
            state.verify_cache.insert(plaintext, false).await;
            unauthorized()
        }
        Err(VerifyError::Cancelled) => unauthorized(),
    }
}
