use std::{fs::File, io};

pub(crate) fn preserve_metadata(source: &File, target: &File) -> io::Result<()> {
    target.set_permissions(source.metadata()?.permissions())?;
    #[cfg(target_os = "macos")]
    {
        use std::os::fd::AsRawFd;
        use std::os::unix::fs::MetadataExt;
        let source_meta = source.metadata()?;
        let target_meta = target.metadata()?;
        // Both descriptors remain owned/alive for these synchronous calls.
        if source_meta.uid() != target_meta.uid() || source_meta.gid() != target_meta.gid() {
            let result =
                unsafe { libc::fchown(target.as_raw_fd(), source_meta.uid(), source_meta.gid()) };
            if result != 0 {
                return Err(io::Error::last_os_error());
            }
        }
        let result = unsafe {
            libc::fcopyfile(
                source.as_raw_fd(),
                target.as_raw_fd(),
                std::ptr::null_mut(),
                libc::COPYFILE_ACL | libc::COPYFILE_XATTR,
            )
        };
        if result != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}
