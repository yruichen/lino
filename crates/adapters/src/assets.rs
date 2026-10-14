//! Document-relative, bounded image reads and root-scoped no-clobber imports.
use crate::workspace::FileWorkspace;
use lino_application::{
    assets::{image_mime, AssetPort, ImageContent, MAX_IMAGE_BYTES},
    ports::StorageError,
};
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::{Component, Path, PathBuf},
};

pub struct FileAssets {
    root: FileWorkspace,
    directory: String,
}
fn io(error: std::io::Error) -> StorageError {
    match error.kind() {
        std::io::ErrorKind::NotFound => StorageError::NotFound,
        std::io::ErrorKind::PermissionDenied => StorageError::Denied,
        _ => StorageError::Io(error.to_string()),
    }
}
pub fn read_selected(path: &Path) -> Result<ImageContent, StorageError> {
    if !fs::symlink_metadata(path).map_err(io)?.is_file() {
        return Err(StorageError::UnsupportedFile);
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    let file = options.open(path).map_err(io)?;
    if !file.metadata().map_err(io)?.is_file() {
        return Err(StorageError::UnsupportedFile);
    }
    let mut bytes = Vec::new();
    file.take(MAX_IMAGE_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(io)?;
    Ok(ImageContent {
        mime: image_mime(&bytes)?.into(),
        bytes,
    })
}
impl FileAssets {
    pub fn for_document(path: &Path) -> Result<Self, StorageError> {
        let root = FileWorkspace::open(path.parent().ok_or(StorageError::Denied)?)?;
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or(StorageError::UnsupportedFile)?;
        Ok(Self {
            root,
            directory: format!("{name}.assets"),
        })
    }
    pub fn resolve(&self, source: &str) -> Result<std::path::PathBuf, StorageError> {
        self.root.ordinary_file(&decode_source(source)?)
    }
    /// Images may live beside a document's parent directories. Resolve the
    /// exact Markdown destination; this read path never grants write scope.
    pub fn resolve_image(&self, source: &str) -> Result<PathBuf, StorageError> {
        resolve_image_path(Some(self.root.root()), source)
    }

    pub fn copy_to(&self, target_document: &Path, sources: &[String]) -> Result<(), StorageError> {
        let target = FileWorkspace::open(target_document.parent().ok_or(StorageError::Denied)?)?;
        if self.root.resolve("", false)? == target.resolve("", false)? {
            return Ok(());
        }
        let mut total = 0usize;
        for source in sources {
            let relative = decode_source(source)?;
            if Path::new(&relative).is_absolute() {
                self.read_image(source)?;
                continue;
            }
            let image = self.read_image(source)?;
            total = total
                .checked_add(image.bytes.len())
                .ok_or(StorageError::LimitExceeded)?;
            if total > 64 * 1024 * 1024 {
                return Err(StorageError::LimitExceeded);
            }
            // Resolve each directory through the root policy before creating it.
            let mut prefix = std::path::PathBuf::new();
            for part in Path::new(&relative)
                .parent()
                .ok_or(StorageError::Denied)?
                .components()
            {
                prefix.push(part);
                let directory =
                    target.resolve(prefix.to_str().ok_or(StorageError::Denied)?, true)?;
                match fs::create_dir(&directory) {
                    Ok(()) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                    Err(error) => return Err(io(error)),
                }
                if !target
                    .resolve(prefix.to_str().ok_or(StorageError::Denied)?, false)?
                    .is_dir()
                {
                    return Err(StorageError::UnsupportedFile);
                }
            }
            let destination = target.resolve(&relative, true)?;
            if destination.try_exists().map_err(io)? {
                if read_selected(&destination)?.bytes == image.bytes {
                    continue;
                }
                return Err(StorageError::ChangedExternally);
            }
            let parent = destination.parent().ok_or(StorageError::Denied)?;
            let mut temp = tempfile::NamedTempFile::new_in(parent).map_err(io)?;
            temp.write_all(&image.bytes).map_err(io)?;
            temp.as_file().sync_all().map_err(io)?;
            match temp.persist_noclobber(&destination) {
                Ok(_) => {}
                Err(error) if error.error.kind() == std::io::ErrorKind::AlreadyExists => {
                    if read_selected(&destination)?.bytes != image.bytes {
                        return Err(StorageError::ChangedExternally);
                    }
                }
                Err(error) => return Err(io(error.error)),
            }
            #[cfg(unix)]
            fs::File::open(parent).map_err(io)?.sync_all().map_err(io)?;
        }
        Ok(())
    }
}
fn decode_source(source: &str) -> Result<String, StorageError> {
    // Decode Markdown URL destinations exactly once before path validation.
    let mut bytes = Vec::with_capacity(source.len());
    let mut chars = source.bytes();
    while let Some(byte) = chars.next() {
        if byte == b'%' {
            let a = chars.next().and_then(|c| (c as char).to_digit(16));
            let b = chars.next().and_then(|c| (c as char).to_digit(16));
            let (a, b) = a.zip(b).ok_or(StorageError::Denied)?;
            bytes.push((a * 16 + b) as u8);
        } else {
            bytes.push(byte);
        }
    }
    String::from_utf8(bytes).map_err(|_| StorageError::Denied)
}
/// Shared read resolver for bound documents and absolute references in drafts.
pub fn resolve_image_path(directory: Option<&Path>, source: &str) -> Result<PathBuf, StorageError> {
    let decoded = decode_source(source)?;
    let input = Path::new(&decoded);
    if decoded.contains('\0') {
        return Err(StorageError::Denied);
    }
    let absolute = input.is_absolute();
    let mut path = if absolute {
        PathBuf::new()
    } else {
        directory.ok_or(StorageError::Denied)?.to_path_buf()
    };
    for part in input.components() {
        match part {
            Component::RootDir | Component::Prefix(_) if absolute => path.push(part),
            Component::CurDir => {}
            Component::ParentDir => {
                if !path.pop() {
                    return Err(StorageError::Denied);
                }
            }
            Component::Normal(name) => {
                path.push(name);
                if fs::symlink_metadata(&path)
                    .map_err(io)?
                    .file_type()
                    .is_symlink()
                {
                    return Err(StorageError::UnsupportedFile);
                }
            }
            _ => return Err(StorageError::Denied),
        }
    }
    if !fs::symlink_metadata(&path).map_err(io)?.is_file() {
        return Err(StorageError::UnsupportedFile);
    }
    Ok(path)
}

impl AssetPort for FileAssets {
    fn read_image(&self, source: &str) -> Result<ImageContent, StorageError> {
        read_selected(&self.resolve_image(source)?)
    }
    fn import_image(&self, name: &str, bytes: &[u8]) -> Result<String, StorageError> {
        let mime = image_mime(bytes)?;
        let extension = match mime {
            "image/png" => "png",
            "image/jpeg" => "jpg",
            "image/gif" => "gif",
            "image/webp" => "webp",
            "image/bmp" => "bmp",
            "image/tiff" => "tiff",
            "image/avif" => "avif",
            "image/heic" => "heic",
            _ => "svg",
        };
        let stem = Path::new(name)
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("image");
        let stem: String = stem
            .chars()
            .filter(|c| c.is_alphanumeric() || matches!(c, '-' | '_' | ' '))
            .take(80)
            .collect();
        let stem = if stem.trim().is_empty() {
            "image"
        } else {
            stem.trim()
        };
        let directory = self.root.resolve(&self.directory, true)?;
        match fs::create_dir(&directory) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(io(e)),
        }
        let directory = self.root.resolve(&self.directory, false)?;
        let mut temporary = tempfile::NamedTempFile::new_in(&directory).map_err(io)?;
        temporary.write_all(bytes).map_err(io)?;
        temporary.as_file().sync_all().map_err(io)?;
        for suffix in 0..10_000 {
            let name = if suffix == 0 {
                format!("{stem}.{extension}")
            } else {
                format!("{stem}-{suffix}.{extension}")
            };
            let target = self
                .root
                .resolve(&format!("{}/{name}", self.directory), true)?;
            match temporary.persist_noclobber(target) {
                Ok(file) => {
                    file.sync_all().map_err(io)?;
                    #[cfg(unix)]
                    {
                        fs::File::open(&directory)
                            .map_err(io)?
                            .sync_all()
                            .map_err(io)?;
                    }
                    return Ok(format!("{}/{name}", self.directory));
                }
                Err(e) if e.error.kind() == std::io::ErrorKind::AlreadyExists => temporary = e.file,
                Err(e) => return Err(io(e.error)),
            }
        }
        Err(StorageError::LimitExceeded)
    }
}
