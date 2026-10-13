use lino_application::{
    ports::StorageError,
    workspace::{Entry, Listing, Mutation, SearchMatcher, SearchOptions, WorkspacePort},
};
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::{Component, Path, PathBuf},
    time::UNIX_EPOCH,
};

pub struct FileWorkspace {
    root: PathBuf,
}
fn error(e: std::io::Error) -> StorageError {
    match e.kind() {
        std::io::ErrorKind::NotFound => StorageError::NotFound,
        std::io::ErrorKind::PermissionDenied => StorageError::Denied,
        std::io::ErrorKind::AlreadyExists => StorageError::ChangedExternally,
        _ => StorageError::Io(e.to_string()),
    }
}
impl FileWorkspace {
    pub fn open(root: &Path) -> Result<Self, StorageError> {
        if !fs::symlink_metadata(root).map_err(error)?.is_dir() {
            return Err(StorageError::UnsupportedFile);
        }
        Ok(Self {
            root: root.canonicalize().map_err(error)?,
        })
    }
    pub fn root(&self) -> &Path {
        &self.root
    }
    pub fn resolve(&self, relative: &str, new: bool) -> Result<PathBuf, StorageError> {
        let path = Path::new(relative);
        if path.is_absolute()
            || path
                .components()
                .any(|part| !matches!(part, Component::Normal(_)))
        {
            return Err(StorageError::Denied);
        }
        let full = self.root.join(path);
        let mut current = self.root.clone();
        for part in path.components() {
            current.push(part);
            match fs::symlink_metadata(&current) {
                Ok(meta) if meta.file_type().is_symlink() => {
                    return Err(StorageError::UnsupportedFile)
                }
                Err(e) if new && current == full && e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(error(e)),
                _ => {}
            }
        }
        let full = if new && !full.try_exists().map_err(error)? {
            full.parent()
                .ok_or(StorageError::Denied)?
                .canonicalize()
                .map_err(error)?
                .join(full.file_name().ok_or(StorageError::Denied)?)
        } else {
            full.canonicalize().map_err(error)?
        };
        if !full.starts_with(&self.root) {
            return Err(StorageError::Denied);
        }
        Ok(full)
    }
    pub fn ordinary_file(&self, relative: &str) -> Result<PathBuf, StorageError> {
        let path = self.resolve(relative, false)?;
        if !fs::symlink_metadata(&path).map_err(error)?.is_file() {
            return Err(StorageError::UnsupportedFile);
        }
        Ok(path)
    }
}
impl WorkspacePort for FileWorkspace {
    fn list(&self, path: &str, hidden: bool) -> Result<Listing, StorageError> {
        let directory = self.resolve(path, false)?;
        let mut listing = Listing {
            entries: Vec::new(),
            truncated: false,
        };
        for entry in fs::read_dir(directory).map_err(error)? {
            let entry = entry.map_err(error)?;
            let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
                continue;
            };
            if name == ".git"
                || name == "node_modules"
                || name == "target"
                || (!hidden && name.starts_with('.'))
            {
                continue;
            }
            let meta = match fs::symlink_metadata(entry.path()) {
                Ok(meta) => meta,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                Err(e) => return Err(error(e)),
            };
            if meta.file_type().is_symlink() || !(meta.is_file() || meta.is_dir()) {
                continue;
            }
            if listing.entries.len() == 5000 {
                listing.truncated = true;
                break;
            }
            listing.entries.push(Entry {
                path: if path.is_empty() {
                    name.clone()
                } else {
                    format!("{path}/{name}")
                },
                name,
                directory: meta.is_dir(),
                bytes: meta.len(),
                modified: meta
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                    .map(|t| t.as_secs())
                    .unwrap_or(0),
            });
        }
        listing.entries.sort_by_cached_key(|entry| {
            (
                std::cmp::Reverse(entry.directory),
                entry.name.to_lowercase(),
                entry.name.clone(),
            )
        });
        Ok(listing)
    }
    fn read(&self, path: &str) -> Result<String, StorageError> {
        let path = self.ordinary_file(path)?;
        let mut options = OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NOFOLLOW);
        }
        let file = options.open(path).map_err(error)?;
        let mut bytes = Vec::new();
        file.take(4 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map_err(error)?;
        if bytes.len() > 4 * 1024 * 1024 {
            return Err(StorageError::LimitExceeded);
        }
        if bytes.contains(&0) {
            return Err(StorageError::UnsupportedEncoding);
        }
        String::from_utf8(bytes)
            .map(|text| {
                text.strip_prefix('\u{feff}')
                    .unwrap_or(&text)
                    .replace("\r\n", "\n")
                    .replace('\r', "\n")
            })
            .map_err(|_| StorageError::UnsupportedEncoding)
    }
    fn mutate(&self, operation: Mutation, source: &str, target: &str) -> Result<(), StorageError> {
        if target.is_empty() {
            return Err(StorageError::Denied);
        }
        let destination = self.resolve(target, true)?;
        // Destination conflicts are rejected again by the final publication.
        if destination.try_exists().map_err(error)? {
            return Err(StorageError::ChangedExternally);
        }
        match operation {
            Mutation::NewFile => {
                OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(destination)
                    .map_err(error)?
                    .sync_all()
                    .map_err(error)?;
            }
            Mutation::NewDirectory => fs::create_dir(destination).map_err(error)?,
            Mutation::Copy => {
                if source.is_empty() {
                    return Err(StorageError::Denied);
                }
                let source = self.resolve(source, false)?;
                let metadata = fs::symlink_metadata(&source).map_err(error)?;
                if metadata.is_dir() {
                    if destination.starts_with(&source) {
                        return Err(StorageError::Denied);
                    }
                    let staging =
                        tempfile::tempdir_in(destination.parent().ok_or(StorageError::Denied)?)
                            .map_err(error)?;
                    copy_directory(&source, staging.path(), 0, &mut 0, &mut (128 * 1024 * 1024))?;
                    rename_noclobber(staging.path(), &destination).map_err(error)?;
                } else {
                    copy_file(&source, &destination, 64 * 1024 * 1024)?;
                }
            }
            Mutation::Move => {
                if source.is_empty() {
                    return Err(StorageError::Denied);
                }
                let source = self.resolve(source, false)?;
                if destination.starts_with(&source) {
                    return Err(StorageError::Denied);
                }
                rename_noclobber(&source, &destination).map_err(error)?;
            }
        }
        Ok(())
    }
}
fn copy_file(source: &Path, destination: &Path, remaining: u64) -> Result<u64, StorageError> {
    let meta = fs::symlink_metadata(source).map_err(error)?;
    if !meta.is_file() {
        return Err(StorageError::UnsupportedFile);
    }
    let remaining = remaining.min(64 * 1024 * 1024);
    if meta.len() > remaining {
        return Err(StorageError::LimitExceeded);
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    let input = options.open(source).map_err(error)?;
    let mut temp =
        tempfile::NamedTempFile::new_in(destination.parent().ok_or(StorageError::Denied)?)
            .map_err(error)?;
    crate::platform::preserve_metadata(&input, temp.as_file()).map_err(error)?;
    let written = std::io::copy(&mut input.take(remaining + 1), &mut temp).map_err(error)?;
    if written > remaining {
        return Err(StorageError::LimitExceeded);
    }
    temp.flush().map_err(error)?;
    temp.as_file().sync_all().map_err(error)?;
    temp.persist_noclobber(destination)
        .map_err(|e| error(e.error))?;
    Ok(written)
}
fn copy_directory(
    source: &Path,
    destination: &Path,
    depth: usize,
    count: &mut usize,
    remaining: &mut u64,
) -> Result<(), StorageError> {
    if depth > 64 {
        return Err(StorageError::LimitExceeded);
    }
    for entry in fs::read_dir(source).map_err(error)? {
        let entry = entry.map_err(error)?;
        *count += 1;
        if *count > 10_000 {
            return Err(StorageError::LimitExceeded);
        }
        let meta = fs::symlink_metadata(entry.path()).map_err(error)?;
        let target = destination.join(entry.file_name());
        if meta.file_type().is_symlink() {
            return Err(StorageError::UnsupportedFile);
        }
        if meta.is_dir() {
            fs::create_dir(&target).map_err(error)?;
            copy_directory(&entry.path(), &target, depth + 1, count, remaining)?;
            fs::set_permissions(&target, meta.permissions()).map_err(error)?;
        } else {
            *remaining -= copy_file(&entry.path(), &target, *remaining)?;
        }
    }
    Ok(())
}

fn rename_noclobber(source: &Path, destination: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::{ffi::CString, os::unix::ffi::OsStrExt};
        let source = CString::new(source.as_os_str().as_bytes())?;
        let destination = CString::new(destination.as_os_str().as_bytes())?;
        // Owned C strings remain alive throughout the synchronous OS call.
        #[cfg(target_os = "macos")]
        let result =
            unsafe { libc::renamex_np(source.as_ptr(), destination.as_ptr(), libc::RENAME_EXCL) };
        #[cfg(target_os = "linux")]
        let result = unsafe {
            libc::renameat2(
                libc::AT_FDCWD,
                source.as_ptr(),
                libc::AT_FDCWD,
                destination.as_ptr(),
                libc::RENAME_NOREPLACE,
            )
        };
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        return Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "Exclusive rename is unavailable",
        ));
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        return if result == 0 {
            Ok(())
        } else {
            Err(std::io::Error::last_os_error())
        };
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn MoveFileW(existing: *const u16, new: *const u16) -> i32;
        }
        let source: Vec<u16> = source.as_os_str().encode_wide().chain(Some(0)).collect();
        let destination: Vec<u16> = destination
            .as_os_str()
            .encode_wide()
            .chain(Some(0))
            .collect();
        // MoveFileW refuses existing destinations. Buffers live through the call.
        let result = unsafe { MoveFileW(source.as_ptr(), destination.as_ptr()) };
        if result != 0 {
            Ok(())
        } else {
            Err(std::io::Error::last_os_error())
        }
    }
}
pub struct Matcher(regex::Regex);
impl Matcher {
    pub fn compile(options: &SearchOptions) -> Result<Self, StorageError> {
        if options.text.is_empty() || options.text.len() > 4096 {
            return Err(StorageError::LimitExceeded);
        }
        let pattern = if options.regex {
            options.text.clone()
        } else {
            regex::escape(&options.text)
        };
        let pattern = if options.whole_word {
            format!("\\b(?:{pattern})\\b")
        } else {
            pattern
        };
        regex::RegexBuilder::new(&pattern)
            .case_insensitive(!options.case_sensitive)
            .size_limit(1024 * 1024)
            .build()
            .map(Self)
            .map_err(|e| StorageError::Io(e.to_string()))
    }
}
impl SearchMatcher for Matcher {
    fn matches(&self, text: &str) -> bool {
        self.0.is_match(text)
    }
}

pub fn trash_path(path: &Path) -> Result<(), StorageError> {
    trash::delete(path).map_err(|e| StorageError::Io(e.to_string()))
}
