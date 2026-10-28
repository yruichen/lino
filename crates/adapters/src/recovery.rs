//! Versioned, bounded recovery records: small JSON header + exact UTF-8 body.
//! Atomic replacement keeps the preceding complete copy on a failed write.
use lino_application::{
    ports::StorageError,
    recovery::{RecoveredText, RecoveryEntry, RecoveryPort, RecoverySnapshot},
};
use lino_document::{TextFormat, MAX_DOCUMENT_BYTES};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
};
use tempfile::NamedTempFile;

const MAGIC: &[u8; 8] = b"OTDRAFT1";
const HEADER_LIMIT: usize = 16 * 1024;
const RECORD_LIMIT: usize = 32;
const BYTE_LIMIT: u64 = 256 * 1024 * 1024;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Header {
    version: u32,
    revision: u64,
    label: Option<String>,
    utf8_bom: bool,
    bytes: u64,
    checksum: String,
}
pub struct FileRecovery {
    root: PathBuf,
    _lock: File,
}
fn io(error: std::io::Error) -> StorageError {
    StorageError::Io(error.to_string())
}
fn invalid() -> StorageError {
    StorageError::Io("恢复副本损坏或版本不支持；已保留原始副本。".into())
}
fn checksum(header: &Header, body: &[u8]) -> Result<String, StorageError> {
    let metadata = serde_json::to_vec(&(
        header.version,
        header.revision,
        &header.label,
        header.utf8_bom,
        header.bytes,
    ))
    .map_err(|_| invalid())?;
    let mut hash = blake3::Hasher::new();
    hash.update(&metadata);
    hash.update(body);
    Ok(hash.finalize().to_hex().to_string())
}
impl FileRecovery {
    pub fn open(root: &Path) -> Result<Self, StorageError> {
        fs::create_dir_all(root).map_err(io)?;
        if !fs::symlink_metadata(root).map_err(io)?.is_dir() {
            return Err(StorageError::UnsupportedFile);
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(root, fs::Permissions::from_mode(0o700)).map_err(io)?;
        }
        let path = root.join("owner.lock");
        let mut options = fs::OpenOptions::new();
        options.create(true).truncate(false).read(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        let lock = options.open(path).map_err(io)?;
        lock.try_lock()
            .map_err(|e| StorageError::Io(format!("恢复目录已被其他进程占用或无法锁定：{e}")))?;
        Ok(Self {
            root: root.to_owned(),
            _lock: lock,
        })
    }
    fn path(&self, key: &str) -> Result<PathBuf, StorageError> {
        if !key.starts_with("draft-")
            || !key.ends_with(".recovery")
            || key.len() > 96
            || !key
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'.' || b == b'_')
        {
            return Err(StorageError::UnsupportedFile);
        }
        Ok(self.root.join(key))
    }
    fn files(&self) -> Result<Vec<(String, u64)>, StorageError> {
        let mut files = Vec::new();
        for (index, entry) in fs::read_dir(&self.root).map_err(io)?.enumerate() {
            if index >= 128 {
                return Err(StorageError::LimitExceeded);
            }
            let entry = entry.map_err(io)?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if !name.ends_with(".recovery")
                || !name.starts_with("draft-")
                || name.len() > 96
                || !name
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'.' || b == b'_')
            {
                // Stray files are not recovery records and must not block the
                // recovery store. Valid-looking corrupt records remain visible
                // through header() as problem entries.
                continue;
            }
            self.path(&name)?;
            if files.len() >= RECORD_LIMIT {
                return Err(StorageError::LimitExceeded);
            }
            files.push((name, fs::symlink_metadata(entry.path()).map_err(io)?.len()));
        }
        files.sort_by(|a, b| a.0.cmp(&b.0));
        Ok(files)
    }
    fn total_bytes(&self) -> Result<u64, StorageError> {
        // Count interrupted staging files and nested leftovers too; repeated
        // crashes must not bypass the disk budget. Never follow symlinks.
        let mut total = 0u64;
        let mut pending = vec![self.root.clone()];
        let mut entries = 0usize;
        while let Some(directory) = pending.pop() {
            for entry in fs::read_dir(directory).map_err(io)? {
                entries += 1;
                if entries > 128 {
                    return Err(StorageError::LimitExceeded);
                }
                let path = entry.map_err(io)?.path();
                let metadata = fs::symlink_metadata(&path).map_err(io)?;
                if metadata.is_dir() {
                    pending.push(path);
                } else {
                    total = total
                        .checked_add(metadata.len())
                        .ok_or(StorageError::LimitExceeded)?;
                }
            }
        }
        Ok(total)
    }
    fn header(&self, key: &str) -> Result<(File, Header), StorageError> {
        let path = self.path(key)?;
        let metadata = fs::symlink_metadata(&path).map_err(|error| match error.kind() {
            std::io::ErrorKind::NotFound => StorageError::NotFound,
            std::io::ErrorKind::PermissionDenied => StorageError::Denied,
            _ => io(error),
        })?;
        if !metadata.is_file() || metadata.len() > (MAX_DOCUMENT_BYTES + HEADER_LIMIT + 12) as u64 {
            return Err(invalid());
        }
        let mut options = fs::OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NOFOLLOW);
        }
        let mut file = options.open(path).map_err(io)?;
        let mut prefix = [0u8; 12];
        file.read_exact(&mut prefix).map_err(|_| invalid())?;
        if &prefix[..8] != MAGIC {
            return Err(invalid());
        }
        let length = u32::from_le_bytes(prefix[8..].try_into().unwrap()) as usize;
        if length > HEADER_LIMIT {
            return Err(invalid());
        }
        let mut bytes = vec![0; length];
        file.read_exact(&mut bytes).map_err(|_| invalid())?;
        let header: Header = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
        if header.version != 1
            || header.bytes > MAX_DOCUMENT_BYTES as u64
            || file.metadata().map_err(io)?.len() != header.bytes + length as u64 + 12
        {
            return Err(invalid());
        }
        Ok((file, header))
    }
    fn sync_directory(&self) -> Result<(), StorageError> {
        #[cfg(unix)]
        {
            File::open(&self.root)
                .and_then(|f| f.sync_all())
                .map_err(io)
        }
        #[cfg(not(unix))]
        {
            Err(StorageError::Io(
                "此平台尚未实现恢复目录的持久化确认。".into(),
            ))
        }
    }
}
impl RecoveryPort for FileRecovery {
    fn list(&self) -> Result<Vec<RecoveryEntry>, StorageError> {
        self.files()?
            .into_iter()
            .map(|(key, _)| {
                let (label, problem) = match self.header(&key) {
                    Ok((_, header)) => (header.label, None),
                    Err(_) => (None, Some("无法读取恢复副本；原始文件已保留。".into())),
                };
                Ok(RecoveryEntry {
                    key,
                    label,
                    problem,
                })
            })
            .collect()
    }
    fn read(&self, key: &str) -> Result<RecoveredText, StorageError> {
        let (file, header) = self.header(key)?;
        let mut bytes = Vec::new();
        file.take(MAX_DOCUMENT_BYTES as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(io)?;
        if bytes.len() as u64 != header.bytes || checksum(&header, &bytes)? != header.checksum {
            return Err(invalid());
        }
        Ok(RecoveredText {
            text: String::from_utf8(bytes).map_err(|_| invalid())?,
            format: TextFormat {
                utf8_bom: header.utf8_bom,
            },
            label: header.label,
        })
    }
    fn write(
        &mut self,
        key: Option<&str>,
        value: &RecoverySnapshot,
    ) -> Result<(String, bool), StorageError> {
        let text = value.snapshot.text();
        let mut metadata = Header {
            version: 1,
            revision: value.snapshot.revision().value(),
            label: value.label.clone(),
            utf8_bom: value.format.utf8_bom,
            bytes: text.len() as u64,
            checksum: String::new(),
        };
        metadata.checksum = checksum(&metadata, text.as_bytes())?;
        let header = serde_json::to_vec(&metadata).map_err(|_| invalid())?;
        if header.len() > HEADER_LIMIT || text.len() > MAX_DOCUMENT_BYTES {
            return Err(StorageError::LimitExceeded);
        }
        let files = self.files()?;
        let old_bytes = files
            .iter()
            .find(|(name, _)| Some(name.as_str()) == key)
            .map(|(_, n)| *n)
            .unwrap_or(0);
        if (old_bytes == 0 && files.len() >= RECORD_LIMIT)
            || self.total_bytes()?.saturating_sub(old_bytes)
                + (header.len() + text.len() + 12) as u64
                > BYTE_LIMIT
        {
            return Err(StorageError::LimitExceeded);
        }
        let mut temp = NamedTempFile::new_in(&self.root).map_err(io)?;
        temp.write_all(MAGIC)
            .and_then(|_| temp.write_all(&(header.len() as u32).to_le_bytes()))
            .and_then(|_| temp.write_all(&header))
            .and_then(|_| temp.write_all(text.as_bytes()))
            .map_err(io)?;
        temp.as_file().sync_all().map_err(io)?;
        let key = match key {
            Some(key) => {
                temp.persist(self.path(key)?).map_err(|e| io(e.error))?;
                key.to_owned()
            }
            None => {
                // Reserve a collision-free name without ever overwriting another draft.
                let reserved = tempfile::Builder::new()
                    .prefix("draft-")
                    .suffix(".recovery")
                    .tempfile_in(&self.root)
                    .map_err(io)?
                    .into_temp_path();
                // Close the destination handle before replacement on Windows;
                // TempPath still cleans up the reservation if persistence fails.
                let key = reserved.file_name().unwrap().to_string_lossy().into_owned();
                temp.persist(&reserved).map_err(|e| io(e.error))?;
                // Keep the destination path; dropping TempPath would delete the new record.
                reserved.keep().map_err(|e| io(e.error))?;
                key
            }
        };
        let durable = self.sync_directory().is_ok();
        Ok((key, durable))
    }
    fn retire(&mut self, key: &str) -> Result<(), StorageError> {
        match fs::remove_file(self.path(key)?) {
            Ok(()) => (),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
            Err(e) => return Err(io(e)),
        }
        self.sync_directory()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lino_document::Snapshot;
    fn draft(text: &str) -> RecoverySnapshot {
        RecoverySnapshot {
            snapshot: Snapshot::new(text.into()).unwrap(),
            format: TextFormat { utf8_bom: true },
            label: Some("草稿.md".into()),
        }
    }
    #[test]
    fn snapshot_roundtrip_lock_and_explicit_retirement() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = FileRecovery::open(dir.path()).unwrap();
        assert!(FileRecovery::open(dir.path()).is_err());
        fs::write(dir.path().join("foreign.recovery"), b"not a Lino draft").unwrap();
        assert!(store.list().unwrap().is_empty());
        let (key, durable) = store.write(None, &draft("中👩🏽‍💻\r\nA\rB\n")).unwrap();
        #[cfg(unix)]
        assert!(durable);
        #[cfg(not(unix))]
        assert!(!durable);
        drop(store);
        let mut store = FileRecovery::open(dir.path()).unwrap();
        let recovered = store.read(&key).unwrap();
        assert_eq!(recovered.text, "中👩🏽‍💻\r\nA\rB\n");
        assert!(recovered.format.utf8_bom);
        assert_eq!(recovered.label.as_deref(), Some("草稿.md"));
        store.write(Some(&key), &draft("next")).unwrap();
        assert_eq!(store.list().unwrap().len(), 1);
        assert_eq!(store.read(&key).unwrap().text, "next");
        #[cfg(unix)]
        {
            store.retire(&key).unwrap();
            store.retire(&key).unwrap();
            assert!(store.list().unwrap().is_empty());
        }
    }
    #[test]
    fn corrupt_truncated_and_unknown_version_records_are_preserved() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = FileRecovery::open(dir.path()).unwrap();
        let (key, _) = store.write(None, &draft("source")).unwrap();
        let path = dir.path().join(&key);
        let original = fs::read(&path).unwrap();
        let mut corrupt = original.clone();
        *corrupt.last_mut().unwrap() ^= 1;
        fs::write(&path, &corrupt).unwrap();
        assert!(store.read(&key).is_err());
        assert_eq!(fs::read(&path).unwrap(), corrupt);
        fs::write(&path, &original[..20]).unwrap();
        assert!(store.read(&key).is_err());
        assert!(store.list().unwrap()[0].problem.is_some());
        let mut changed_metadata = original.clone();
        let length = u32::from_le_bytes(changed_metadata[8..12].try_into().unwrap()) as usize;
        let header = String::from_utf8(changed_metadata[12..12 + length].to_vec()).unwrap();
        let altered = header.replace("草稿", "伪稿");
        changed_metadata[12..12 + length].copy_from_slice(altered.as_bytes());
        fs::write(&path, &changed_metadata).unwrap();
        assert!(store.read(&key).is_err());
        let mut future = original;
        future[7] = b'9';
        fs::write(&path, &future).unwrap();
        assert!(store.read(&key).is_err());
        assert_eq!(fs::read(&path).unwrap(), future);
        assert!(store.read("../outside").is_err());
    }
    #[test]
    fn quota_failure_preserves_preceding_snapshot() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = FileRecovery::open(dir.path()).unwrap();
        let (key, _) = store.write(None, &draft("previous")).unwrap();
        // Sparse fixture exercises accounting without allocating 256 MiB in RAM.
        let occupied = File::create(dir.path().join("draft-quota.recovery")).unwrap();
        occupied.set_len(BYTE_LIMIT).unwrap();
        assert_eq!(
            store.write(Some(&key), &draft("new")).unwrap_err(),
            StorageError::LimitExceeded
        );
        assert_eq!(store.read(&key).unwrap().text, "previous");
    }
    #[cfg(unix)]
    #[test]
    fn symlink_records_never_read_outside_recovery_directory() {
        use std::os::unix::fs::symlink;
        let dir = tempfile::tempdir().unwrap();
        let outside = dir.path().join("private");
        fs::write(&outside, "untouched").unwrap();
        let root = dir.path().join("recovery");
        let store = FileRecovery::open(&root).unwrap();
        symlink(&outside, root.join("draft-link.recovery")).unwrap();
        assert!(store.read("draft-link.recovery").is_err());
        assert_eq!(fs::read_to_string(outside).unwrap(), "untouched");
    }
}
