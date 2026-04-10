use std::os::unix::process::CommandExt;

const NIX_STORE: &str = "/run/current-system/sw/bin/nix-store";
const SUDO:      &str = "/run/wrappers/bin/sudo";
const ACTIVATE:  &str = "/run/current-system/sw/bin/activate-rs";

fn parse(cmd: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut in_single_quote = false;

    for ch in cmd.chars() {
        match ch {
            '\'' => in_single_quote = !in_single_quote,
            ' ' if !in_single_quote => {
                if !current.is_empty() {
                    tokens.push(std::mem::take(&mut current));
                }
            }
            c => current.push(c),
        }
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    tokens
}

fn is_nix_store_path(s: &str) -> bool {
    s.starts_with("/nix/store/")
        && s.len() > "/nix/store/".len()
        && !s.contains("..")
        && s.chars().all(|c| c.is_ascii() && !c.is_ascii_control())
}

fn is_tmp_path(s: &str) -> bool {
    s.starts_with("/tmp/") || s == "/tmp"
}

fn is_profile_path(s: &str) -> bool {
    s.starts_with("/nix/var/nix/profiles/")
        && !s.contains("..")
}

fn is_u32(s: &str) -> bool {
    s.parse::<u32>().is_ok()
}

enum ActivateArgs {
    Activate {
        store_path: String,
        profile_path: String,
        temp_path: String,
        confirm_timeout: String,
        magic_rollback: bool,
        auto_rollback: bool,
    },
    Wait {
        store_path: String,
        temp_path: String,
        activation_timeout: String,
    },
    Revoke {
        profile_path: String,
    },
}

fn parse_activate_args(args: &[String]) -> Option<ActivateArgs> {
    match args {
        // activate-rs activate '<store>' --profile-path '<profile>'
        //   --temp-path '<tmp>' --confirm-timeout <n>
        //   [--magic-rollback] [--auto-rollback]
        [sub, store, rest @ ..] if sub == "activate" => {
            if !is_nix_store_path(store) {
                return None;
            }

            let mut profile_path = None;
            let mut temp_path = None;
            let mut confirm_timeout = None;
            let mut magic_rollback = false;
            let mut auto_rollback = false;

            let mut i = 0;
            while i < rest.len() {
                match rest[i].as_str() {
                    "--profile-path" => {
                        i += 1;
                        let v = rest.get(i)?;
                        if !is_profile_path(v) { return None; }
                        profile_path = Some(v.clone());
                    }
                    "--temp-path" => {
                        i += 1;
                        let v = rest.get(i)?;
                        if !is_tmp_path(v) { return None; }
                        temp_path = Some(v.clone());
                    }
                    "--confirm-timeout" => {
                        i += 1;
                        let v = rest.get(i)?;
                        if !is_u32(v) { return None; }
                        confirm_timeout = Some(v.clone());
                    }
                    "--magic-rollback"  => magic_rollback = true,
                    "--auto-rollback"   => auto_rollback = true,
                    _ => return None, // unknown arg — reject
                }
                i += 1;
            }

            Some(ActivateArgs::Activate {
                store_path: store.clone(),
                profile_path: profile_path?,
                temp_path: temp_path?,
                confirm_timeout: confirm_timeout?,
                magic_rollback,
                auto_rollback,
            })
        }

        // activate-rs wait '<store>' --temp-path '<tmp>'
        //   --activation-timeout <n>
        [sub, store, rest @ ..] if sub == "wait" => {
            if !is_nix_store_path(store) {
                return None;
            }

            let mut temp_path = None;
            let mut activation_timeout = None;

            let mut i = 0;
            while i < rest.len() {
                match rest[i].as_str() {
                    "--temp-path" => {
                        i += 1;
                        let v = rest.get(i)?;
                        if !is_tmp_path(v) { return None; }
                        temp_path = Some(v.clone());
                    }
                    "--activation-timeout" => {
                        i += 1;
                        let v = rest.get(i)?;
                        if !is_u32(v) { return None; }
                        activation_timeout = Some(v.clone());
                    }
                    _ => return None,
                }
                i += 1;
            }

            Some(ActivateArgs::Wait {
                store_path: store.clone(),
                temp_path: temp_path?,
                activation_timeout: activation_timeout?,
            })
        }

        // activate-rs revoke --profile-path '<profile>'
        [sub, rest @ ..] if sub == "revoke" => {
            let mut profile_path = None;

            let mut i = 0;
            while i < rest.len() {
                match rest[i].as_str() {
                    "--profile-path" => {
                        i += 1;
                        let v = rest.get(i)?;
                        if !is_profile_path(v) { return None; }
                        profile_path = Some(v.clone());
                    }
                    _ => return None,
                }
                i += 1;
            }

            Some(ActivateArgs::Revoke {
                profile_path: profile_path?,
            })
        }

        _ => None,
    }
}

enum Command {
    NixServeWrite,
    NixServe,
    Activate(ActivateArgs),
}

fn classify(argv: &[String]) -> Option<Command> {
    match argv.as_ref() {
        [a, b, c] if a == "nix-store" && b == "--serve" && c == "--write" =>
            Some(Command::NixServeWrite),
        [a, b] if a == "nix-store" && b == "--serve" =>
            Some(Command::NixServe),
        [a, b, rest @ ..] if a == "sudo" && b == ACTIVATE =>
            Some(Command::Activate(parse_activate_args(rest)?)),
        _ => None,
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() != 3 || args[1] != "-c" {
        eprintln!("interactive sessions not permitted");
        std::process::exit(1);
    }

    let argv = parse(&args[2]);

    let err = match classify(&argv) {
        Some(Command::NixServeWrite) => {
            std::process::Command::new(NIX_STORE)
                .args(["--serve", "--write"])
                .exec()
        }
        Some(Command::NixServe) => {
            std::process::Command::new(NIX_STORE)
                .args(["--serve"])
                .exec()
        }
        Some(Command::Activate(act)) => {
            let mut cmd = std::process::Command::new(SUDO);
            cmd.arg(ACTIVATE);
            match act {
                ActivateArgs::Activate {
                    store_path, profile_path, temp_path,
                    confirm_timeout, magic_rollback, auto_rollback,
                } => {
                    cmd.args(["activate", &store_path,
                              "--profile-path", &profile_path,
                              "--temp-path", &temp_path,
                              "--confirm-timeout", &confirm_timeout]);
                    if magic_rollback { cmd.arg("--magic-rollback"); }
                    if auto_rollback  { cmd.arg("--auto-rollback"); }
                }
                ActivateArgs::Wait { store_path, temp_path, activation_timeout } => {
                    cmd.args(["wait", &store_path,
                              "--temp-path", &temp_path,
                              "--activation-timeout", &activation_timeout]);
                }
                ActivateArgs::Revoke { profile_path } => {
                    cmd.args(["revoke",
                              "--profile-path", &profile_path]);
                }
            }
            cmd.exec()
        }
        None => {
            eprintln!("command not permitted: {:?}", argv);
            std::process::exit(1);
        }
    };

    eprintln!("exec failed: {}", err);
    std::process::exit(1);
}
