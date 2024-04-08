use anyhow::Result;
use dialoguer::Input;
use shellexpand_utils::expand;
use std::{fs, path::PathBuf};
use toml_edit::{DocumentMut, Item};

use crate::{account, ui::THEME};

use super::Config;

#[macro_export]
macro_rules! wizard_warn {
    ($($arg:tt)*) => {
	println!("{}", console::style(format!($($arg)*)).yellow().bold());
    };
}

#[macro_export]
macro_rules! wizard_prompt {
    ($($arg:tt)*) => {
	format!("{}", console::style(format!($($arg)*)).italic())
    };
}

#[macro_export]
macro_rules! wizard_log {
    ($($arg:tt)*) => {
	println!();
	println!("{}", console::style(format!($($arg)*)).underlined());
	println!();
    };
}

pub async fn configure(path: &PathBuf) -> Result<Config> {
    wizard_log!("Configuring your default account");

    let mut config = Config::default();

    let (account_name, account_config) = account::wizard::configure().await?;
    config.accounts.insert(account_name, account_config);

    let path = Input::with_theme(&*THEME)
        .with_prompt(wizard_prompt!(
            "Where would you like to save your configuration?"
        ))
        .default(path.to_string_lossy().to_string())
        .interact()?;
    let path = expand::path(path);

    println!("Writing the configuration to {path:?}…");
    let toml = pretty_serialize(&config)?;
    fs::create_dir_all(path.parent().unwrap_or(&path))?;
    fs::write(path, toml)?;

    println!("Exiting the wizard…");
    Ok(config)
}

fn pretty_serialize(config: &Config) -> Result<String> {
    let mut doc: DocumentMut = toml::to_string(&config)?.parse()?;

    doc.iter_mut().for_each(|(_, item)| {
        if let Some(item) = item.as_table_mut() {
            item.iter_mut().for_each(|(_, item)| {
                let keys = ["folder", "envelope"];
                set_tables_dotted(item, keys);
                for key in keys {
                    if let Some(item) = get_table_mut(item, key) {
                        set_table_dotted(item, "filter");
                    }
                }

                for source in ["left", "right"] {
                    set_table_dotted(item, source);
                    if let Some(item) = get_table_mut(item, source) {
                        set_table_dotted(item, "backend");
                        if let Some(item) = get_table_mut(item, "backend") {
                            set_tables_dotted(item, ["passwd", "oauth2"]);
                        }

                        let keys = ["folder", "flag", "message"];
                        set_tables_dotted(item, keys);
                        for key in keys {
                            if let Some(item) = get_table_mut(item, key) {
                                set_table_dotted(item, "permissions");
                            }
                        }
                    }
                }
            })
        }
    });

    Ok(doc.to_string())
}

fn get_table_mut<'a>(item: &'a mut Item, key: &'a str) -> Option<&'a mut Item> {
    item.get_mut(key).filter(|item| item.is_table())
}

fn set_table_dotted(item: &mut Item, key: &str) {
    if let Some(table) = get_table_mut(item, key).and_then(|item| item.as_table_mut()) {
        table.set_dotted(true)
    }
}

fn set_tables_dotted<'a>(item: &'a mut Item, keys: impl IntoIterator<Item = &'a str>) {
    for key in keys {
        set_table_dotted(item, key)
    }
}

#[cfg(test)]
mod test {
    use std::collections::HashMap;

    use crate::{account::config::AccountConfig, config::Config};

    use super::pretty_serialize;

    fn assert_eq(config: AccountConfig, expected_toml: &str) {
        let config = Config {
            accounts: HashMap::from_iter([("test".into(), config)]),
            ..Default::default()
        };

        let toml = pretty_serialize(&config).expect("serialize error");
        assert_eq!(toml, expected_toml);

        let expected_config = toml::from_str(&toml).expect("deserialize error");
        assert_eq!(config, expected_config);
    }

    #[test]
    fn pretty_serialize_default() {
        assert_eq(
            AccountConfig {
                email: "test@localhost".into(),
                ..Default::default()
            },
            r#"[accounts.test]
email = "test@localhost"
"#,
        )
    }

    #[cfg(feature = "account-sync")]
    #[test]
    fn pretty_serialize_sync_all() {
        use email::account::sync::config::SyncConfig;

        assert_eq(
            AccountConfig {
                email: "test@localhost".into(),
                sync: Some(SyncConfig {
                    enable: Some(false),
                    dir: Some("/tmp/test".into()),
                    ..Default::default()
                }),
                ..Default::default()
            },
            r#"[accounts.test]
email = "test@localhost"
sync.enable = false
sync.dir = "/tmp/test"
"#,
        );
    }

    #[cfg(feature = "account-sync")]
    #[test]
    fn pretty_serialize_sync_include() {
        use email::{
            account::sync::config::SyncConfig,
            folder::sync::config::{FolderSyncConfig, FolderSyncStrategy},
        };
        use std::collections::BTreeSet;

        use crate::folder::config::FolderConfig;

        assert_eq(
            AccountConfig {
                email: "test@localhost".into(),
                sync: Some(SyncConfig {
                    enable: Some(true),
                    dir: Some("/tmp/test".into()),
                    ..Default::default()
                }),
                folder: Some(FolderConfig {
                    sync: Some(FolderSyncConfig {
                        filter: FolderSyncStrategy::Include(BTreeSet::from_iter(["test".into()])),
                        ..Default::default()
                    }),
                    ..Default::default()
                }),
                ..Default::default()
            },
            r#"[accounts.test]
email = "test@localhost"
sync.enable = true
sync.dir = "/tmp/test"
folder.sync.filter.include = ["test"]
folder.sync.permissions.create = true
folder.sync.permissions.delete = true
"#,
        );
    }

    #[cfg(feature = "imap")]
    #[test]
    fn pretty_serialize_imap_passwd_cmd() {
        use email::{
            account::config::passwd::PasswdConfig,
            imap::config::{ImapAuthConfig, ImapConfig},
        };
        use secret::Secret;

        assert_eq(
            AccountConfig {
                email: "test@localhost".into(),
                imap: Some(ImapConfig {
                    host: "localhost".into(),
                    port: 143,
                    login: "test@localhost".into(),
                    auth: ImapAuthConfig::Passwd(PasswdConfig(Secret::new_command(
                        "pass show test",
                    ))),
                    ..Default::default()
                }),
                ..Default::default()
            },
            r#"[accounts.test]
email = "test@localhost"
imap.host = "localhost"
imap.port = 143
imap.login = "test@localhost"
imap.passwd.command = "pass show test"
"#,
        );
    }

    #[cfg(feature = "imap")]
    #[test]
    fn pretty_serialize_imap_passwd_cmds() {
        use email::{
            account::config::passwd::PasswdConfig,
            imap::config::{ImapAuthConfig, ImapConfig},
        };
        use secret::Secret;

        assert_eq(
            AccountConfig {
                email: "test@localhost".into(),
                imap: Some(ImapConfig {
                    host: "localhost".into(),
                    port: 143,
                    login: "test@localhost".into(),
                    auth: ImapAuthConfig::Passwd(PasswdConfig(Secret::new_command(vec![
                        "pass show test",
                        "tr -d '[:blank:]'",
                    ]))),
                    ..Default::default()
                }),
                ..Default::default()
            },
            r#"[accounts.test]
email = "test@localhost"
imap.host = "localhost"
imap.port = 143
imap.login = "test@localhost"
imap.passwd.command = ["pass show test", "tr -d '[:blank:]'"]
"#,
        );
    }

    #[cfg(feature = "imap")]
    #[test]
    fn pretty_serialize_imap_oauth2() {
        use email::{
            account::config::oauth2::OAuth2Config,
            imap::config::{ImapAuthConfig, ImapConfig},
        };

        assert_eq(
            AccountConfig {
                email: "test@localhost".into(),
                imap: Some(ImapConfig {
                    host: "localhost".into(),
                    port: 143,
                    login: "test@localhost".into(),
                    auth: ImapAuthConfig::OAuth2(OAuth2Config {
                        client_id: "client-id".into(),
                        auth_url: "auth-url".into(),
                        token_url: "token-url".into(),
                        ..Default::default()
                    }),
                    ..Default::default()
                }),
                ..Default::default()
            },
            r#"[accounts.test]
email = "test@localhost"
imap.host = "localhost"
imap.port = 143
imap.login = "test@localhost"
imap.oauth2.method = "xoauth2"
imap.oauth2.client-id = "client-id"
imap.oauth2.auth-url = "auth-url"
imap.oauth2.token-url = "token-url"
imap.oauth2.pkce = false
imap.oauth2.scopes = []
"#,
        );
    }

    #[cfg(feature = "maildir")]
    #[test]
    fn pretty_serialize_maildir() {
        use email::maildir::config::MaildirConfig;

        assert_eq(
            AccountConfig {
                email: "test@localhost".into(),
                maildir: Some(MaildirConfig {
                    root_dir: "/tmp/test".into(),
                }),
                ..Default::default()
            },
            r#"[accounts.test]
email = "test@localhost"
maildir.root-dir = "/tmp/test"
"#,
        );
    }

    #[cfg(feature = "smtp")]
    #[test]
    fn pretty_serialize_smtp_passwd_cmd() {
        use email::{
            account::config::passwd::PasswdConfig,
            smtp::config::{SmtpAuthConfig, SmtpConfig},
        };
        use secret::Secret;

        assert_eq(
            AccountConfig {
                email: "test@localhost".into(),
                smtp: Some(SmtpConfig {
                    host: "localhost".into(),
                    port: 143,
                    login: "test@localhost".into(),
                    auth: SmtpAuthConfig::Passwd(PasswdConfig(Secret::new_command(
                        "pass show test",
                    ))),
                    ..Default::default()
                }),
                ..Default::default()
            },
            r#"[accounts.test]
email = "test@localhost"
smtp.host = "localhost"
smtp.port = 143
smtp.login = "test@localhost"
smtp.passwd.command = "pass show test"
"#,
        );
    }

    #[cfg(feature = "smtp")]
    #[test]
    fn pretty_serialize_smtp_passwd_cmds() {
        use email::{
            account::config::passwd::PasswdConfig,
            smtp::config::{SmtpAuthConfig, SmtpConfig},
        };
        use secret::Secret;

        assert_eq(
            AccountConfig {
                email: "test@localhost".into(),
                smtp: Some(SmtpConfig {
                    host: "localhost".into(),
                    port: 143,
                    login: "test@localhost".into(),
                    auth: SmtpAuthConfig::Passwd(PasswdConfig(Secret::new_command(vec![
                        "pass show test",
                        "tr -d '[:blank:]'",
                    ]))),
                    ..Default::default()
                }),
                ..Default::default()
            },
            r#"[accounts.test]
email = "test@localhost"
smtp.host = "localhost"
smtp.port = 143
smtp.login = "test@localhost"
smtp.passwd.command = ["pass show test", "tr -d '[:blank:]'"]
"#,
        );
    }

    #[cfg(feature = "smtp")]
    #[test]
    fn pretty_serialize_smtp_oauth2() {
        use email::{
            account::config::oauth2::OAuth2Config,
            smtp::config::{SmtpAuthConfig, SmtpConfig},
        };

        assert_eq(
            AccountConfig {
                email: "test@localhost".into(),
                smtp: Some(SmtpConfig {
                    host: "localhost".into(),
                    port: 143,
                    login: "test@localhost".into(),
                    auth: SmtpAuthConfig::OAuth2(OAuth2Config {
                        client_id: "client-id".into(),
                        auth_url: "auth-url".into(),
                        token_url: "token-url".into(),
                        ..Default::default()
                    }),
                    ..Default::default()
                }),
                ..Default::default()
            },
            r#"[accounts.test]
email = "test@localhost"
smtp.host = "localhost"
smtp.port = 143
smtp.login = "test@localhost"
smtp.oauth2.method = "xoauth2"
smtp.oauth2.client-id = "client-id"
smtp.oauth2.auth-url = "auth-url"
smtp.oauth2.token-url = "token-url"
smtp.oauth2.pkce = false
smtp.oauth2.scopes = []
"#,
        );
    }

    #[cfg(feature = "pgp-cmds")]
    #[test]
    fn pretty_serialize_pgp_cmds() {
        use email::account::config::pgp::PgpConfig;

        assert_eq(
            AccountConfig {
                email: "test@localhost".into(),
                pgp: Some(PgpConfig::Cmds(Default::default())),
                ..Default::default()
            },
            r#"[accounts.test]
email = "test@localhost"
pgp.backend = "cmds"
"#,
        );
    }
}
