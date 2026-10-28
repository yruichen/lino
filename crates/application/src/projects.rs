use lino_document::FileRef;

/// Opaque identity for a LaTeX project. It is never a filesystem path.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct ProjectId(pub u64);

/// Identity of the root source file inside the storage registry.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct RootFileRef(pub FileRef);

/// Monotonic project identity used to invalidate in-flight compiler results.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Ord, PartialOrd)]
pub struct ProjectGeneration(pub u64);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LatexProject {
    id: ProjectId,
    root: RootFileRef,
    generation: ProjectGeneration,
}

impl LatexProject {
    pub fn new(id: ProjectId, root: RootFileRef) -> Self {
        Self {
            id,
            root,
            generation: ProjectGeneration(1),
        }
    }

    pub fn id(self) -> ProjectId {
        self.id
    }

    pub fn root(self) -> RootFileRef {
        self.root
    }

    pub fn generation(self) -> ProjectGeneration {
        self.generation
    }

    /// Advance the project identity after a root, dependency, resource, or
    /// compile-profile change. Old jobs retain their original generation.
    pub fn advance_generation(&mut self) -> Option<ProjectGeneration> {
        self.generation.0 = self.generation.0.checked_add(1)?;
        Some(self.generation)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn project_generation_is_monotonic_and_old_values_remain_usable() {
        let mut project = LatexProject::new(ProjectId(7), RootFileRef(FileRef(11)));
        let old = project.generation();
        assert_eq!(old, ProjectGeneration(1));
        assert_eq!(project.advance_generation(), Some(ProjectGeneration(2)));
        assert_eq!(old, ProjectGeneration(1));
        assert_eq!(project.id(), ProjectId(7));
        assert_eq!(project.root(), RootFileRef(FileRef(11)));
    }
}
