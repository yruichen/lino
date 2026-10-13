use lino_application::ports::{DiskVersion, LoadedFile, StorageCommit, StorageError, StoragePort};
use lino_document::{FileRef, TextFormat, MAX_DOCUMENT_BYTES};
use std::{
    collections::HashMap,
    fs::{self, File, Metadata, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    sync::Mutex,
};
use tempfile::NamedTempFile;

#[derive(Default)]
struct Registry {
    next: u64,
    paths: HashMap<FileRef, PathBuf>,
}

#[derive(Default)]
pub struct FileStorage {
    registry: Mutex<Registry>,
}

fn io_error(error: io::Error) -> StorageError {
    match error.kind() {
        io::ErrorKind::NotFound => StorageError::NotFound,
        io::ErrorKind::PermissionDenied => StorageError::Denied,
        _ => StorageError::Io(error.to_string()),
    }
}

impl FileStorage {
    pub fn register(&self, path: &Path) -> Result<(FileRef, String), StorageError> {
        let parent = path
            .parent()
            .ok_or(StorageError::UnsupportedFile)?
            .canonicalize()
            .map_err(io_error)?;
        let name = path.file_name().ok_or(StorageError::UnsupportedFile)?;
        let path = parent.join(name);
        // Use the real spelling of ordinary files on case-insensitive disks.
        // File symlinks retain their original path and are rejected by load.
        let metadata = fs::symlink_metadata(&path)
            .ok()
            .filter(|meta| meta.is_file());
        let path = if metadata.is_some() {
            path.canonicalize().map_err(io_error)?
        } else {
            path
        };
        let label = name.to_string_lossy().into_owned();
        let mut registry = self
            .registry
            .lock()
            .map_err(|_| StorageError::Io("Storage lock poisoned".into()))?;
        if let Some((id, _)) = registry.paths.iter().find(|(_, old)| {
            if **old == path {
                return true;
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::MetadataExt;
                if let Some(meta) = &metadata {
                    return fs::symlink_metadata(old).ok().is_some_and(|other| {
                        other.is_file() && other.dev() == meta.dev() && other.ino() == meta.ino()
                    });
                }
            }
            false
        }) {
            return Ok((*id, label));
        }
        if registry.paths.len() >= 256 {
            return Err(StorageError::LimitExceeded);
        }
        registry.next = registry
            .next
            .checked_add(1)
            .ok_or(StorageError::LimitExceeded)?;
        let id = FileRef(registry.next);
        registry.paths.insert(id, path);
        Ok((id, label))
    }
    pub fn unregister(&self, file: FileRef) {
        if let Ok(mut registry) = self.registry.lock() {
            registry.paths.remove(&file);
        }
    }
    pub fn registered_paths(&self) -> Result<Vec<(FileRef, PathBuf)>, StorageError> {
        Ok(self
            .registry
            .lock()
            .map_err(|_| StorageError::Io("Storage lock poisoned".into()))?
            .paths
            .iter()
            .map(|(file, path)| (*file, path.clone()))
            .collect())
    }
    pub fn is_registered_below(&self, path: &Path) -> Result<bool, StorageError> {
        let metadata = fs::symlink_metadata(path).ok();
        Ok(self.registered_paths()?.iter().any(|(_, candidate)| {
            if candidate.starts_with(path) {
                return true;
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::MetadataExt;
                if let Some(meta) = metadata.as_ref().filter(|meta| meta.is_file()) {
                    return fs::symlink_metadata(candidate).ok().is_some_and(|other| {
                        other.is_file() && other.dev() == meta.dev() && other.ino() == meta.ino()
                    });
                }
            }
            #[cfg(not(unix))]
            let _ = &metadata;
            false
        }))
    }
    pub fn path(&self, file: FileRef) -> Result<PathBuf, StorageError> {
        self.registry
            .lock()
            .map_err(|_| StorageError::Io("Storage lock poisoned".into()))?
            .paths
            .get(&file)
            .cloned()
            .ok_or(StorageError::NotFound)
    }
}

fn signature(bytes: &[u8], metadata: &Metadata) -> DiskVersion {
    let mut identity = blake3::Hasher::new();
    identity.update(bytes);
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        identity.update(&metadata.dev().to_le_bytes());
        identity.update(&metadata.ino().to_le_bytes());
        identity.update(&metadata.mode().to_le_bytes());
        identity.update(&metadata.uid().to_le_bytes());
        identity.update(&metadata.gid().to_le_bytes());
        identity.update(&metadata.ctime().to_le_bytes());
        identity.update(&metadata.ctime_nsec().to_le_bytes());
    }
    #[cfg(not(unix))]
    {
        identity.update(&[u8::from(metadata.permissions().readonly())]);
    }
    DiskVersion(identity.finalize().to_hex().to_string())
}

fn read_file(path: &Path) -> Result<(File, Vec<u8>, DiskVersion), StorageError> {
    let metadata = fs::symlink_metadata(path).map_err(io_error)?;
    if !metadata.file_type().is_file() {
        return Err(StorageError::UnsupportedFile);
    }
    if metadata.len() > MAX_DOCUMENT_BYTES as u64 {
        return Err(StorageError::LimitExceeded);
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    let mut file = options.open(path).map_err(io_error)?;
    let before = file.metadata().map_err(io_error)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.dev() != before.dev() || metadata.ino() != before.ino() {
            return Err(StorageError::ChangedExternally);
        }
    }
    let mut bytes = Vec::new();
    (&mut file)
        .take(MAX_DOCUMENT_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(io_error)?;
    if bytes.len() > MAX_DOCUMENT_BYTES {
        return Err(StorageError::LimitExceeded);
    }
    let after = file.metadata().map_err(io_error)?;
    if before.len() != after.len() || before.modified().ok() != after.modified().ok() {
        return Err(StorageError::ChangedExternally);
    }
    let version = signature(&bytes, &after);
    Ok((file, bytes, version))
}

impl StoragePort for FileStorage {
    fn load(&self, file: FileRef) -> Result<LoadedFile, StorageError> {
        let path = self.path(file)?;
        let (_, bytes, version) = read_file(&path)?;
        let bom = bytes.starts_with(&[0xef, 0xbb, 0xbf]);
        let text = String::from_utf8(bytes[if bom { 3 } else { 0 }..].to_vec())
            .map_err(|_| StorageError::UnsupportedEncoding)?;
        Ok(LoadedFile {
            text,
            version,
            format: TextFormat { utf8_bom: bom },
            label: path.file_name().unwrap().to_string_lossy().into_owned(),
        })
    }
    fn inspect(&self, file: FileRef) -> Result<Option<DiskVersion>, StorageError> {
        match read_file(&self.path(file)?) {
            Ok((_, _, version)) => Ok(Some(version)),
            Err(StorageError::NotFound) => Ok(None),
            Err(error) => Err(error),
        }
    }
    fn commit(&self, request: &StorageCommit) -> Result<(DiskVersion, bool), StorageError> {
        let mut bytes = Vec::with_capacity(request.snapshot.text().len() + 3);
        if request.format.utf8_bom {
            bytes.extend_from_slice(&[0xef, 0xbb, 0xbf]);
        }
        bytes.extend_from_slice(request.snapshot.text().as_bytes());
        self.commit_bytes(request.target, request.expected.clone(), &bytes)
    }
}
impl FileStorage {
    /// Shared atomic output path for document text and binary exports.
    pub fn commit_bytes(
        &self,
        target: FileRef,
        expected: Option<DiskVersion>,
        bytes: &[u8],
    ) -> Result<(DiskVersion, bool), StorageError> {
        if bytes.len() > MAX_DOCUMENT_BYTES {
            return Err(StorageError::LimitExceeded);
        }
        let path = self.path(target)?;
        let parent = path.parent().ok_or(StorageError::UnsupportedFile)?;
        let original = match read_file(&path) {
            Ok((file, _, version)) if Some(&version) == expected.as_ref() => Some(file),
            Err(StorageError::NotFound) if expected.is_none() => None,
            Ok(_) | Err(StorageError::NotFound) => return Err(StorageError::ChangedExternally),
            Err(error) => return Err(error),
        };
        if let Some(original) = &original {
            if original
                .metadata()
                .map_err(io_error)?
                .permissions()
                .readonly()
            {
                return Err(StorageError::Denied);
            }
            let mut options = OpenOptions::new();
            options.write(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.custom_flags(libc::O_NOFOLLOW);
            }
            let writable = options.open(&path).map_err(io_error)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::MetadataExt;
                let checked = writable.metadata().map_err(io_error)?;
                let prior = original.metadata().map_err(io_error)?;
                if checked.ino() != prior.ino() || checked.dev() != prior.dev() {
                    return Err(StorageError::ChangedExternally);
                }
            }
            drop(writable);
        }
        let mut temp = NamedTempFile::new_in(parent).map_err(io_error)?;
        if let Some(original) = &original {
            crate::platform::preserve_metadata(original, temp.as_file()).map_err(io_error)?;
        }
        temp.write_all(bytes).map_err(io_error)?;
        temp.as_file().sync_all().map_err(io_error)?;
        // Recheck after preparation. This is optimistic conflict detection,
        // not a cross-process compare-and-swap with arbitrary outside writers.
        if self.inspect(target)? != expected {
            return Err(StorageError::ChangedExternally);
        }
        // Release our destination handle before Windows' MoveFileEx replacement;
        // metadata preservation and the final conflict check are complete now.
        drop(original);
        let persisted = if expected.is_none() {
            temp.persist_noclobber(&path).map_err(|error| {
                if error.error.kind() == io::ErrorKind::AlreadyExists {
                    StorageError::ChangedExternally
                } else {
                    io_error(error.error)
                }
            })?
        } else {
            temp.persist(&path).map_err(|error| io_error(error.error))?
        };
        let version = signature(bytes, &persisted.metadata().map_err(io_error)?);
        if self.inspect(target)? != Some(version.clone()) {
            return Err(StorageError::ChangedExternally);
        }
        drop(persisted);
        #[cfg(unix)]
        let durable = File::open(parent).and_then(|dir| dir.sync_all()).is_ok();
        #[cfg(not(unix))]
        let durable = false;
        Ok((version, durable))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lino_document::Snapshot;
    #[test]
    fn bom_and_mixed_line_endings_survive_atomic_save() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("文档.md");
        let bytes = b"\xef\xbb\xbf# title\r\n\r\nA\nB\rC";
        fs::write(&path, bytes).unwrap();
        let storage = FileStorage::default();
        let (file, _) = storage.register(&path).unwrap();
        let loaded = storage.load(file).unwrap();
        let (_, _) = storage
            .commit(&StorageCommit {
                target: file,
                expected: Some(loaded.version),
                snapshot: Snapshot::new(loaded.text).unwrap(),
                format: loaded.format,
            })
            .unwrap();
        assert_eq!(fs::read(&path).unwrap(), bytes);
        assert_eq!(fs::read_dir(directory.path()).unwrap().count(), 1);
    }
    #[test]
    fn same_size_external_change_is_detected_and_not_overwritten() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("test.md");
        fs::write(&path, "first").unwrap();
        let storage = FileStorage::default();
        let (file, _) = storage.register(&path).unwrap();
        let loaded = storage.load(file).unwrap();
        fs::write(&path, "other").unwrap();
        assert_eq!(
            storage
                .commit(&StorageCommit {
                    target: file,
                    expected: Some(loaded.version),
                    snapshot: Snapshot::new("mine".into()).unwrap(),
                    format: loaded.format
                })
                .unwrap_err(),
            StorageError::ChangedExternally
        );
        assert_eq!(fs::read_to_string(path).unwrap(), "other");
    }
    #[test]
    fn unknown_resource_and_unsupported_encoding_do_not_write_files() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("invalid.md");
        fs::write(&path, [0xff, 0xfe, 0]).unwrap();
        let storage = FileStorage::default();
        let (file, _) = storage.register(&path).unwrap();
        assert_eq!(
            storage.load(file).unwrap_err(),
            StorageError::UnsupportedEncoding
        );
        assert_eq!(
            storage.inspect(FileRef(999)).unwrap_err(),
            StorageError::NotFound
        );
        assert_eq!(fs::read(path).unwrap(), [0xff, 0xfe, 0]);
    }
    #[cfg(unix)]
    #[test]
    fn symlinks_and_readonly_targets_are_rejected_without_replacing_files() {
        use std::os::unix::fs::{symlink, PermissionsExt};
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("readonly.md");
        fs::write(&path, "original").unwrap();
        let storage = FileStorage::default();
        let (file, _) = storage.register(&path).unwrap();
        let loaded = storage.load(file).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o444)).unwrap();
        let expected = storage.inspect(file).unwrap();
        assert_eq!(
            storage
                .commit(&StorageCommit {
                    target: file,
                    expected,
                    snapshot: lino_document::Snapshot::new("changed".into()).unwrap(),
                    format: loaded.format
                })
                .unwrap_err(),
            StorageError::Denied
        );
        let link = directory.path().join("alias.md");
        symlink(&path, &link).unwrap();
        let (alias, _) = storage.register(&link).unwrap();
        assert_eq!(
            storage.load(alias).unwrap_err(),
            StorageError::UnsupportedFile
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), "original");
        assert_eq!(fs::read_dir(directory.path()).unwrap().count(), 2);
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn macos_atomic_replace_preserves_permissions_and_extended_attributes() {
        use std::os::{fd::AsRawFd, unix::fs::PermissionsExt};
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("attributes.md");
        fs::write(&path, "original").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
        let original = File::open(&path).unwrap();
        let name = c"com.lino.fixture";
        let value = b"attribute-preserved";
        // Owned fd/name/value buffers live through each synchronous libc call.
        assert_eq!(
            unsafe {
                libc::fsetxattr(
                    original.as_raw_fd(),
                    name.as_ptr(),
                    value.as_ptr().cast(),
                    value.len(),
                    0,
                    0,
                )
            },
            0
        );
        let storage = FileStorage::default();
        let (file, _) = storage.register(&path).unwrap();
        let loaded = storage.load(file).unwrap();
        storage
            .commit(&StorageCommit {
                target: file,
                expected: Some(loaded.version),
                snapshot: lino_document::Snapshot::new("changed".into()).unwrap(),
                format: loaded.format,
            })
            .unwrap();
        let replaced = File::open(&path).unwrap();
        let mut received = [0u8; 64];
        let length = unsafe {
            libc::fgetxattr(
                replaced.as_raw_fd(),
                name.as_ptr(),
                received.as_mut_ptr().cast(),
                received.len(),
                0,
                0,
            )
        };
        assert_eq!(length, value.len() as isize);
        assert_eq!(&received[..length as usize], value);
        assert_eq!(
            fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o640
        );
    }
}
