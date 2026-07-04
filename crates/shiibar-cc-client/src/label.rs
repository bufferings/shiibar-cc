//! cwd -> display label formatting (DESIGN.md §4.5): if `cwd` is under the
//! home directory, rewrite it to start with `~`; either way, show only the
//! last two path components (or fewer, if the path is shorter). This lives
//! in shiibar-cc-client (rather than duplicated in `shiibar-cc` and the menu
//! bar app) because both consumers need the exact same rule (§4.5:
//! "this formatting will later be used by both the app and the CLI, so it
//! belongs in shiibar-cc-client").
//!
//! DESIGN.md only spells out the home-relative case; for a `cwd` outside
//! the home directory this always falls back to "last two path components,
//! no prefix" (see the M2 completion report for this decision).

/// Format `cwd` for display, using `$HOME` to detect the home-relative case.
pub fn format_cwd_label(cwd: &str) -> String {
    let home = std::env::var("HOME").ok();
    format_cwd_label_with_home(cwd, home.as_deref())
}

/// Same as `format_cwd_label`, but with an explicit `home` (for tests, and
/// for callers that already have it resolved).
pub fn format_cwd_label_with_home(cwd: &str, home: Option<&str>) -> String {
    let is_home_relative =
        matches!(home, Some(h) if !h.is_empty() && (cwd == h || cwd.starts_with(&format!("{h}/"))));

    let components: Vec<&str> = if is_home_relative {
        let h = home.unwrap();
        cwd[h.len()..]
            .split('/')
            .filter(|s| !s.is_empty())
            .collect()
    } else {
        cwd.split('/').filter(|s| !s.is_empty()).collect()
    };

    let tail_start = components.len().saturating_sub(2);
    let tail = components[tail_start..].join("/");

    if is_home_relative {
        if tail.is_empty() {
            "~".to_string()
        } else {
            format!("~/{tail}")
        }
    } else {
        tail
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn home_relative_path_gets_tilde_and_last_two_components() {
        assert_eq!(
            format_cwd_label_with_home(
                "/Users/example/projects/shiibar",
                Some("/Users/example")
            ),
            "~/projects/shiibar"
        );
    }

    #[test]
    fn home_relative_path_with_one_component_shows_what_it_has() {
        assert_eq!(
            format_cwd_label_with_home("/Users/example/shiibar", Some("/Users/example")),
            "~/shiibar"
        );
    }

    #[test]
    fn exactly_home_directory_is_just_tilde() {
        assert_eq!(
            format_cwd_label_with_home("/Users/example", Some("/Users/example")),
            "~"
        );
    }

    #[test]
    fn non_home_path_uses_last_two_components_with_no_prefix() {
        assert_eq!(
            format_cwd_label_with_home("/opt/build/shiibar/worktree", Some("/Users/example")),
            "shiibar/worktree"
        );
    }

    #[test]
    fn no_home_known_falls_back_to_last_two_components() {
        assert_eq!(
            format_cwd_label_with_home("/opt/build/shiibar/worktree", None),
            "shiibar/worktree"
        );
    }

    #[test]
    fn sibling_path_sharing_a_prefix_is_not_treated_as_home_relative() {
        // "/Users/example-other" starts with "/Users/example" as a
        // string, but not as a path component boundary.
        assert_eq!(
            format_cwd_label_with_home("/Users/example-other/x", Some("/Users/example")),
            "example-other/x"
        );
    }
}
