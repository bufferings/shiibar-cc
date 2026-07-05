//! shiibar-cc: CLI for shiibar-ccd (report / list / wait / watch / focus / ...).
//!
//! Spec: docs/DESIGN.md §4.4. Thin by design: argument parsing and wiring
//! the real environment (socket path, `$HOME/.claude/settings.json`,
//! `$PATH`, the real `osascript` runner) into `shiibar-cc`'s library
//! functions, which do the actual work and are what the test suite drives.

use shiibar_cc_client::iterm::Osascript;
use std::path::PathBuf;
use std::time::Duration;

fn main() {
    let mut args = std::env::args().skip(1);
    let cmd = args.next();
    let rest: Vec<String> = args.collect();

    // §4.4: `report` is the sole exception to the exit-code rules — always
    // exit 0, even on failure, so hooks are never blocked.
    if cmd.as_deref() == Some("report") {
        shiibar_cc::report_cmd::run(
            rest.into_iter().next(),
            &shiibar_cc_client::resolve_socket_path(),
        );
        std::process::exit(0);
    }

    let code = match cmd.as_deref() {
        Some("list") => cmd_list(&rest),
        Some("wait") => cmd_wait(&rest),
        Some("watch") => cmd_watch(&rest),
        Some("focus") => cmd_focus(&rest),
        Some("focused") => cmd_focused(&rest),
        Some("reconcile") => cmd_reconcile(&rest),
        Some("remove") => cmd_remove(&rest),
        Some("doctor") => cmd_doctor(&rest),
        _ => {
            print_usage();
            1
        }
    };
    std::process::exit(code);
}

fn print_usage() {
    eprintln!(
        "usage: shiibar-cc <report|list|wait|watch|focus|focused|reconcile|remove|doctor> ..."
    );
    eprintln!("see docs/DESIGN.md §4.4 for each subcommand's arguments");
}

fn current_dir_or_dot() -> PathBuf {
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

fn cmd_list(args: &[String]) -> i32 {
    let json = args.iter().any(|a| a == "--json");
    let report = shiibar_cc::list_cmd::run_list(&shiibar_cc_client::resolve_socket_path(), json);
    if !report.stdout.is_empty() {
        println!("{}", report.stdout);
    }
    if let Some(e) = report.stderr {
        eprintln!("{e}");
    }
    report.exit_code
}

fn cmd_wait(args: &[String]) -> i32 {
    let mut selector = None;
    let mut status_arg = None;
    let mut timeout = None;
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--status" => status_arg = it.next().cloned(),
            "--timeout" => {
                timeout = it
                    .next()
                    .and_then(|s| s.parse::<u64>().ok())
                    .map(Duration::from_secs)
            }
            other if selector.is_none() => selector = Some(other.to_string()),
            other => {
                eprintln!("shiibar-cc wait: unexpected argument '{other}'");
                return 1;
            }
        }
    }
    let (Some(selector), Some(status_arg)) = (selector, status_arg) else {
        eprintln!(
            "usage: shiibar-cc wait <selector> --status idle|working|waiting [--timeout SEC]"
        );
        return 1;
    };
    let Some(want) = shiibar_cc::wait_cmd::parse_status(&status_arg) else {
        eprintln!(
            "shiibar-cc wait: unknown status '{status_arg}' (expected idle|working|waiting)"
        );
        return 1;
    };

    let (code, err) = shiibar_cc::wait_cmd::run_wait(
        &shiibar_cc_client::resolve_socket_path(),
        &selector,
        current_dir_or_dot(),
        want,
        timeout,
    );
    if let Some(e) = err {
        eprintln!("{e}");
    }
    code
}

fn cmd_watch(_args: &[String]) -> i32 {
    shiibar_cc::watch_cmd::run_watch(&shiibar_cc_client::resolve_socket_path(), std::io::stdout())
}

fn cmd_focus(args: &[String]) -> i32 {
    let Some(selector) = args.first() else {
        eprintln!("usage: shiibar-cc focus <selector>");
        return 1;
    };
    let runner = Osascript;
    let report = shiibar_cc::focus_cmd::run_focus(
        &shiibar_cc_client::resolve_socket_path(),
        selector,
        current_dir_or_dot(),
        &runner,
    );
    if let Some(m) = report.message {
        eprintln!("{m}");
    }
    report.exit_code
}

fn cmd_focused(_args: &[String]) -> i32 {
    let runner = Osascript;
    let report = shiibar_cc::focus_cmd::run_focused(&runner);
    if let Some(t) = &report.target {
        println!("{t}");
    }
    if let Some(m) = &report.message {
        eprintln!("{m}");
    }
    report.exit_code
}

fn cmd_reconcile(_args: &[String]) -> i32 {
    let claude_runner = shiibar_cc_client::RealClaudeAgents;
    let ps_runner = shiibar_cc_client::iterm::RealPs;
    let script_runner = Osascript;
    let (code, err) = shiibar_cc::reconcile_cmd::run_reconcile(
        &shiibar_cc_client::resolve_socket_path(),
        &claude_runner,
        &ps_runner,
        &script_runner,
    );
    if let Some(e) = err {
        eprintln!("{e}");
    }
    code
}

fn cmd_remove(args: &[String]) -> i32 {
    let Some(selector) = args.first() else {
        eprintln!("usage: shiibar-cc remove <selector>");
        return 1;
    };
    let (code, err) = shiibar_cc::remove_cmd::run_remove(
        &shiibar_cc_client::resolve_socket_path(),
        selector,
        current_dir_or_dot(),
    );
    if let Some(e) = err {
        eprintln!("{e}");
    }
    code
}

fn cmd_doctor(_args: &[String]) -> i32 {
    let runner = Osascript;
    let settings_path = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".claude/settings.json");
    let report = shiibar_cc::doctor_cmd::run_doctor(
        &shiibar_cc_client::resolve_socket_path(),
        &settings_path,
        std::env::var_os("PATH").as_deref(),
        &runner,
    );
    for line in &report.lines {
        println!("{line}");
    }
    report.exit_code
}
