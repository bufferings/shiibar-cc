//! `shiibarctl watch` (DESIGN.md §4.4): stream `subscribe` events as line
//! JSON to stdout, forever.

use crate::exitcode;
use shiibar_client::connection::Subscription;
use shiibar_proto::codec;
use std::io::Write;
use std::path::Path;

pub fn run_watch(socket_path: &Path, mut out: impl Write) -> i32 {
    let mut sub = match Subscription::open(socket_path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("shiibarctl watch: {e}");
            return exitcode::ERROR;
        }
    };

    loop {
        match sub.next_event(None) {
            Ok(Some(event)) => {
                let line = codec::encode_line(&event).expect("SubscribeEvent always encodes");
                if out.write_all(line.as_bytes()).is_err() {
                    return exitcode::ERROR;
                }
                if out.flush().is_err() {
                    return exitcode::ERROR;
                }
            }
            Ok(None) => unreachable!("no deadline was set, so next_event never times out"),
            Err(e) => {
                eprintln!("shiibarctl watch: {e}");
                return exitcode::ERROR;
            }
        }
    }
}
