//! Test/diagnostic front end for the engine: run one end of an audio session from a shell and
//! watch its events as JSON lines.
//!
//!   remremote-audio-cli send --password PW (--bind PORT | --host H --port P)
//!                            [--exclude-pid PID] [--relay-session B64] [--tone HZ] [--seconds N]
//!   remremote-audio-cli recv --password PW (--bind PORT | --host H --port P)
//!                            [--max-latency MS] [--relay-session B64] [--null] [--dump FILE] [--seconds N]
//!   both: [--output-device ENDPOINT_ID | --output-device-name NAME]   (default: system default)
//!   remremote-audio-cli devices          lists the output devices (Windows)
//!   remremote-audio-cli derive --password PW
//!   remremote-audio-cli version

use std::collections::HashMap;
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine as _;
use remremote_audio::engine::{start_receiver, start_sender, EventSink, RecvConfig, SendConfig};
use remremote_audio::platform::null::NullPlayout;
use remremote_audio::platform::tone::ToneSource;
use remremote_audio::platform::{list_output_devices, system_capture, system_playout, CaptureSource, DeviceSelection, PlayoutSink};
use remremote_audio::{crypto, VERSION};

fn parse_args(args: &[String]) -> (HashMap<String, String>, Vec<String>) {
    let mut options = HashMap::new();
    let mut positional = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];
        if let Some(name) = arg.strip_prefix("--") {
            let next = args.get(i + 1);
            if next.map_or(true, |v| v.starts_with("--")) {
                options.insert(name.to_string(), "true".to_string());
                i += 1;
            } else {
                options.insert(name.to_string(), next.unwrap().clone());
                i += 2;
            }
        } else {
            positional.push(arg.clone());
            i += 1;
        }
    }
    (options, positional)
}

fn session(options: &HashMap<String, String>) -> Result<Option<[u8; 32]>, String> {
    match options.get("relay-session") {
        None => Ok(None),
        Some(encoded) => {
            let bytes = base64::engine::general_purpose::STANDARD.decode(encoded).map_err(|e| e.to_string())?;
            bytes.try_into().map(Some).map_err(|_| "relay session must be 32 bytes".to_string())
        }
    }
}

fn device(options: &HashMap<String, String>) -> DeviceSelection {
    if let Some(id) = options.get("output-device") {
        DeviceSelection::Id(id.clone())
    } else if let Some(name) = options.get("output-device-name") {
        DeviceSelection::Name(name.clone())
    } else {
        DeviceSelection::Default
    }
}

fn events() -> EventSink {
    let out = Mutex::new(std::io::stdout());
    Arc::new(move |value| {
        let mut out = out.lock().unwrap();
        let _ = writeln!(out, "{value}");
        let _ = out.flush();
    })
}

fn run_for(options: &HashMap<String, String>) {
    match options.get("seconds").and_then(|s| s.parse::<u64>().ok()) {
        Some(seconds) => std::thread::sleep(Duration::from_secs(seconds)),
        None => loop {
            std::thread::sleep(Duration::from_secs(3600));
        },
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (options, positional) = parse_args(&args);
    let command = positional.first().map(String::as_str).unwrap_or("");
    let port = options.get("port").and_then(|p| p.parse().ok()).unwrap_or(6837u16);
    let bind = options.get("bind").and_then(|p| p.parse().ok()).unwrap_or(0u16);
    let password = options.get("password").cloned().unwrap_or_default();
    let result: Result<(), String> = match command {
        "version" => {
            println!("{VERSION}");
            Ok(())
        }
        "devices" => (|| {
            for (id, name, is_default) in list_output_devices()? {
                println!("{}{}\t{}", if is_default { "* " } else { "  " }, name, id);
            }
            Ok(())
        })(),
        "derive" => {
            let hex = |bytes: &[u8]| bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
            println!("key         {}", hex(&crypto::derive_key(&password)));
            println!("fingerprint {}", hex(&crypto::fingerprint(&password)));
            Ok(())
        }
        "send" => (|| {
            let capture: Box<dyn CaptureSource> = match options.get("tone") {
                Some(hz) => Box::new(ToneSource::new(hz.parse().map_err(|_| "bad --tone")?)),
                None => system_capture(options.get("exclude-pid").and_then(|p| p.parse().ok()).unwrap_or(0), device(&options))?,
            };
            let mut sender = start_sender(
                SendConfig {
                    password,
                    bind_port: bind,
                    host: options.get("host").cloned(),
                    port,
                    exclude_pid: options.get("exclude-pid").and_then(|p| p.parse().ok()).unwrap_or(0),
                    relay_session: session(&options)?,
                },
                capture,
                events(),
            )?;
            run_for(&options);
            sender.stop();
            Ok(())
        })(),
        "recv" => (|| {
            let playout: Box<dyn PlayoutSink> = if options.contains_key("null") || options.contains_key("dump") {
                Box::new(NullPlayout::new(options.get("dump").map(PathBuf::from)))
            } else {
                system_playout(device(&options))?
            };
            let mut receiver = start_receiver(
                RecvConfig {
                    password,
                    bind_port: bind,
                    host: options.get("host").cloned(),
                    port,
                    max_latency_ms: options.get("max-latency").and_then(|p| p.parse().ok()).unwrap_or(0),
                    relay_session: session(&options)?,
                },
                playout,
                events(),
            )?;
            run_for(&options);
            receiver.stop();
            Ok(())
        })(),
        _ => Err("usage: remremote-audio-cli (send|recv|devices|derive|version) [options]".into()),
    };
    if let Err(message) = result {
        eprintln!("error: {message}");
        std::process::exit(1);
    }
}
