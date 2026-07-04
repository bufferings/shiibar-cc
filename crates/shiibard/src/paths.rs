//! State directory resolution (§2, §9): `~/.local/state/shiibar/` by
//! default, overridable with `SHIIBAR_STATE_DIR` (tests always set this).

use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct StateDir {
    root: PathBuf,
}

impl StateDir {
    /// Resolve from `SHIIBAR_STATE_DIR`, falling back to the default.
    pub fn from_env() -> anyhow::Result<Self> {
        let root = match std::env::var_os("SHIIBAR_STATE_DIR") {
            Some(v) => PathBuf::from(v),
            None => default_root()?,
        };
        Ok(Self { root })
    }

    /// Build directly from a path (used by tests to point at a temp dir).
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn socket(&self) -> PathBuf {
        self.root.join("shiibard.sock")
    }

    pub fn state_json(&self) -> PathBuf {
        self.root.join("state.json")
    }

    pub fn sessions_jsonl(&self) -> PathBuf {
        self.root.join("sessions.jsonl")
    }

    pub fn log_file(&self) -> PathBuf {
        self.root.join("shiibard.log")
    }

    /// Create the directory (0700) if missing.
    pub fn ensure(&self) -> anyhow::Result<()> {
        std::fs::create_dir_all(&self.root)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&self.root, std::fs::Permissions::from_mode(0o700))?;
        }
        Ok(())
    }
}

fn default_root() -> anyhow::Result<PathBuf> {
    let home = std::env::var_os("HOME").ok_or_else(|| anyhow::anyhow!("HOME is not set"))?;
    Ok(PathBuf::from(home).join(".local/state/shiibar"))
}
