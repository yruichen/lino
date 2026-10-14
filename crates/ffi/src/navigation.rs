use crate::{exports::wire_error, BridgeError, DocumentService};
use lino_runtime::DocumentRuntime;
use std::{
    path::Path,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
};
fn json<T: serde::Serialize>(value: &T) -> Result<String, BridgeError> {
    serde_json::to_string(value).map_err(|e| BridgeError::Failed {
        message: e.to_string(),
    })
}
#[derive(Default)]
struct QueryState {
    last: u64,
    cancelled: u64,
    active: Option<Arc<AtomicBool>>,
}
#[derive(uniffi::Object)]
pub struct QuickOpenService {
    runtime: Arc<DocumentRuntime>,
    query: Mutex<QueryState>,
}
#[uniffi::export]
impl DocumentService {
    pub fn configure_navigation(
        &self,
        path: String,
        legacy_locations: Vec<String>,
    ) -> Result<String, BridgeError> {
        json(
            &self
                .runtime
                .configure_navigation(Path::new(&path), legacy_locations)
                .map_err(wire_error)?,
        )
    }
    pub fn navigation(&self) -> Result<String, BridgeError> {
        json(&self.runtime.navigation().map_err(wire_error)?)
    }
    pub fn update_navigation(
        &self,
        revision: u64,
        values_json: String,
    ) -> Result<String, BridgeError> {
        let values =
            lino_runtime::navigation::parse_navigation_values(&values_json).map_err(|e| {
                BridgeError::Failed {
                    message: e.to_string(),
                }
            })?;
        json(
            &self
                .runtime
                .update_navigation(revision, values)
                .map_err(wire_error)?,
        )
    }
    pub fn note_navigation_file(&self, path: String) -> Result<String, BridgeError> {
        json(
            &self
                .runtime
                .note_navigation_file(Path::new(&path))
                .map_err(wire_error)?,
        )
    }
    pub fn invalidate_navigation(&self) {
        self.runtime.invalidate_navigation();
    }
    pub fn quick_open_service(&self) -> Arc<QuickOpenService> {
        Arc::new(QuickOpenService {
            runtime: self.runtime.clone(),
            query: Mutex::default(),
        })
    }
}
#[uniffi::export]
impl QuickOpenService {
    pub fn search(
        &self,
        query_id: u64,
        text: String,
        scope: Option<String>,
        current: Option<String>,
    ) -> Result<String, BridgeError> {
        let token = Arc::new(AtomicBool::new(false));
        {
            let mut query = self.query.lock().map_err(|_| BridgeError::Failed {
                message: "Query lock poisoned".into(),
            })?;
            if query_id <= query.last || query_id <= query.cancelled {
                return json(&lino_runtime::navigation::QuickResults {
                    cancelled: true,
                    ..Default::default()
                });
            }
            query.last = query_id;
            if let Some(previous) = query.active.replace(token.clone()) {
                previous.store(true, Ordering::Relaxed);
            }
        }
        let result = self
            .runtime
            .quick_files(
                &text,
                scope.as_deref().map(Path::new),
                current.as_deref(),
                &token,
            )
            .map_err(wire_error)?;
        json(&result)
    }
    pub fn cancel(&self, query_id: u64) {
        if let Ok(mut query) = self.query.lock() {
            query.cancelled = query.cancelled.max(query_id);
            if query.last <= query_id {
                if let Some(token) = query.active.take() {
                    token.store(true, Ordering::Relaxed);
                }
            }
        }
    }
}
