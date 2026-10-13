//! Atomic opaque settings storage; schema and validation belong to the runtime/use case.
use std::{
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
};
use tempfile::NamedTempFile;

pub struct FileSettings {
    path: PathBuf,
}
impl FileSettings {
    pub fn new(path: &Path) -> Self {
        Self {
            path: path.to_owned(),
        }
    }
    pub fn load(&self) -> io::Result<Option<Vec<u8>>> {
        let file = match fs::File::open(&self.path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        let mut bytes = Vec::new();
        file.take(1024 * 1024 + 1).read_to_end(&mut bytes)?;
        if bytes.len() > 1024 * 1024 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Settings file is too large",
            ));
        }
        Ok(Some(bytes))
    }
    pub fn save(&self, bytes: &[u8]) -> io::Result<bool> {
        let parent = self.path.parent().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "Settings path needs a parent")
        })?;
        fs::create_dir_all(parent)?;
        let mut temp = NamedTempFile::new_in(parent)?;
        temp.write_all(bytes)?;
        temp.as_file().sync_all()?;
        temp.persist(&self.path).map_err(|error| error.error)?;
        #[cfg(unix)]
        let durable = fs::File::open(parent)
            .and_then(|directory| directory.sync_all())
            .is_ok();
        #[cfg(not(unix))]
        let durable = false;
        Ok(durable)
    }
}
