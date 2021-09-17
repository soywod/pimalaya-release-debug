use anyhow::{Context, Result};
use atty::Stream;
use imap::types::Flag;
use lettre::message::header::ContentTransferEncoding;
use log::{debug, error, trace};
use std::{
    borrow::Cow,
    convert::TryFrom,
    fs,
    io::{self, BufRead},
};
use url::Url;

use crate::{
    config::entity::Account,
    domain::{
        imap::service::ImapServiceInterface,
        mbox::entity::Mbox,
        msg::{
            self,
            body::Body,
            entity::{Msg, Msgs},
        },
        smtp::service::SmtpServiceInterface,
    },
    output::service::{OutputService, OutputServiceInterface},
    ui::choice::{self, PostEditChoice},
};

use super::{entity::MsgSerialized, flag::entity::Flags, headers::Headers};

// TODO: move this function to the right folder
fn msg_interaction<ImapService: ImapServiceInterface, SmtpService: SmtpServiceInterface>(
    output: &OutputService,
    msg: &mut Msg,
    imap: &mut ImapService,
    smtp: &mut SmtpService,
) -> Result<bool> {
    // let the user change the body a little bit first, before opening the prompt
    msg.edit_body()?;

    loop {
        match choice::post_edit() {
            Ok(choice) => match choice {
                PostEditChoice::Send => {
                    debug!("sending message…");

                    // prepare the msg to be send
                    let sendable = match msg.to_sendable_msg() {
                        Ok(sendable) => sendable,
                        // In general if an error occured, then this is normally
                        // due to a missing value of a header. So let's give the
                        // user another try and give him/her the chance to fix
                        // that :)
                        Err(err) => {
                            println!("{}", err);
                            println!("Please reedit your msg to make it to a sendable message!");
                            continue;
                        }
                    };
                    smtp.send(&sendable)?;

                    // TODO: Gmail sent mailboxes are called `[Gmail]/Sent`
                    // which creates a conflict, fix this!

                    // let the server know, that the user sent a msg
                    msg.flags.insert(Flag::Seen);
                    let mbox = Mbox::from("Sent");
                    imap.append_msg(&mbox, msg)?;

                    // remove the draft, since we sent it
                    msg::utils::remove_draft()?;
                    output.print("Message successfully sent")?;
                    break;
                }
                // edit the body of the msg
                PostEditChoice::Edit => {
                    // Did something goes wrong when the user changed the
                    // content?
                    if let Err(err) = msg.edit_body() {
                        println!("[ERROR] {}", err);
                        println!(concat!(
                            "Please try to fix the problem by editing",
                            "the msg again."
                        ));
                    }
                }
                PostEditChoice::LocalDraft => break,
                PostEditChoice::RemoteDraft => {
                    debug!("saving to draft…");

                    msg.flags.insert(Flag::Seen);

                    let mbox = Mbox::from("Drafts");
                    match imap.append_msg(&mbox, msg) {
                        Ok(_) => {
                            msg::utils::remove_draft()?;
                            output.print("Message successfully saved to Drafts")?;
                        }
                        Err(err) => {
                            output.print("Cannot save draft to the server")?;
                            return Err(err.into());
                        }
                    };
                    break;
                }
                PostEditChoice::Discard => {
                    msg::utils::remove_draft()?;
                    break;
                }
            },
            Err(err) => error!("{}", err),
        }
    }

    Ok(true)
}

pub fn attachments<ImapService: ImapServiceInterface>(
    uid: &str,
    account: &Account,
    output: &OutputService,
    imap: &mut ImapService,
) -> Result<()> {
    let msg = imap.get_msg(&uid)?;
    let attachments = msg.attachments.clone();

    debug!(
        "{} attachment(s) found for message {}",
        &attachments.len(),
        &uid
    );

    // Iterate through all attachments and download them to the download
    // directory of the account.
    for attachment in &attachments {
        let filepath = account.downloads_dir.join(&attachment.filename);
        debug!("downloading {}…", &attachment.filename);
        fs::write(&filepath, &attachment.body_raw)
            .context(format!("cannot save attachment {:?}", filepath))?;
    }

    debug!(
        "{} attachment(s) successfully downloaded",
        &attachments.len()
    );

    output.print(format!(
        "{} attachment(s) successfully downloaded",
        &attachments.len()
    ))?;

    imap.logout()?;
    Ok(())
}

pub fn copy<ImapService: ImapServiceInterface>(
    uid: &str,
    mbox: Option<&str>,
    output: &OutputService,
    imap: &mut ImapService,
) -> Result<()> {
    let target = Mbox::try_from(mbox)?;
    let mut msg = imap.get_msg(&uid)?;
    // the message, which will be in the new mailbox doesn't need to be seen
    msg.flags.insert(Flag::Seen);
    imap.append_msg(&target, &mut msg)?;
    debug!("message {} successfully copied to folder `{}`", uid, target);
    output.print(format!(
        "Message {} successfully copied to folder `{}`",
        uid, target
    ))?;
    imap.logout()?;
    Ok(())
}

pub fn delete<ImapService: ImapServiceInterface>(
    uid: &str,
    output: &OutputService,
    imap: &mut ImapService,
) -> Result<()> {
    let flags = vec![Flag::Seen, Flag::Deleted];
    imap.add_flags(uid, Flags::from(flags))?;
    imap.expunge()?;
    debug!("message {} successfully deleted", uid);
    output.print(format!("Message {} successfully deleted", uid))?;
    imap.logout()?;
    Ok(())
}

pub fn forward<ImapService: ImapServiceInterface, SmtpService: SmtpServiceInterface>(
    uid: &str,
    attachments_paths: Vec<&str>,
    account: &Account,
    output: &OutputService,
    imap: &mut ImapService,
    smtp: &mut SmtpService,
) -> Result<()> {
    let mut msg = imap.get_msg(&uid)?;
    // prepare to forward it
    msg.change_to_forwarding(&account);
    attachments_paths
        .iter()
        .for_each(|path| msg.add_attachment(path));
    debug!("found {} attachments", attachments_paths.len());
    trace!("attachments: {:?}", attachments_paths);
    // apply changes
    msg_interaction(output, &mut msg, imap, smtp)?;
    imap.logout()?;
    Ok(())
}

pub fn list<ImapService: ImapServiceInterface>(
    page_size: Option<usize>,
    page: usize,
    account: &Account,
    output: &OutputService,
    imap: &mut ImapService,
) -> Result<()> {
    let page_size = page_size.unwrap_or(account.default_page_size);
    let msgs = imap.list_msgs(&page_size, &page)?;
    let msgs = if let Some(ref fetches) = msgs {
        Msgs::try_from(fetches)?
    } else {
        Msgs::new()
    };
    trace!("messages: {:#?}", msgs);
    output.print(msgs)?;
    imap.logout()?;
    Ok(())
}

pub fn mailto<ImapService: ImapServiceInterface, SmtpService: SmtpServiceInterface>(
    url: &Url,
    account: &Account,
    output: &OutputService,
    imap: &mut ImapService,
    smtp: &mut SmtpService,
) -> Result<()> {
    let mut cc = Vec::new();
    let mut bcc = Vec::new();
    let mut subject = Cow::default();
    let mut body = Cow::default();

    for (key, val) in url.query_pairs() {
        match key.as_bytes() {
            b"cc" => {
                cc.push(val.into());
            }
            b"bcc" => {
                bcc.push(val.into());
            }
            b"subject" => {
                subject = val;
            }
            b"body" => {
                body = val;
            }
            _ => (),
        }
    }

    let headers = Headers {
        from: vec![account.address()],
        to: vec![url.path().to_string()],
        encoding: ContentTransferEncoding::Base64,
        bcc: Some(bcc),
        cc: Some(cc),
        signature: Some(account.signature.to_owned()),
        subject: Some(subject.into()),
        ..Headers::default()
    };

    let mut msg = Msg::new_with_headers(&account, headers);
    msg.body = Body::new_with_text(body);
    msg_interaction(output, &mut msg, imap, smtp)?;
    imap.logout()?;
    Ok(())
}

pub fn move_<ImapService: ImapServiceInterface>(
    uid: &str,
    mbox: Option<&str>,
    output: &OutputService,
    imap: &mut ImapService,
) -> Result<()> {
    let target = Mbox::try_from(mbox)?;
    let mut msg = imap.get_msg(&uid)?;
    // create the msg in the target-msgbox
    msg.flags.insert(Flag::Seen);
    imap.append_msg(&target, &mut msg)?;
    debug!("message {} successfully moved to folder `{}`", uid, target);
    output.print(format!(
        "Message {} successfully moved to folder `{}`",
        uid, target
    ))?;
    // delete the msg in the old mailbox
    let flags = vec![Flag::Seen, Flag::Deleted];
    imap.add_flags(uid, Flags::from(flags))?;
    imap.expunge()?;
    imap.logout()?;
    Ok(())
}

pub fn read<ImapService: ImapServiceInterface>(
    uid: &str,
    // TODO: use the mime to select the right body
    _mime: String,
    raw: bool,
    output: &OutputService,
    imap: &mut ImapService,
) -> Result<()> {
    let msg = imap.get_msg(&uid)?;
    if raw {
        output.print(msg.get_raw_as_string()?)?;
    } else {
        output.print(MsgSerialized::try_from(&msg)?)?;
    }
    imap.logout()?;
    Ok(())
}

pub fn reply<ImapService: ImapServiceInterface, SmtpService: SmtpServiceInterface>(
    uid: &str,
    all: bool,
    attachments_paths: Vec<&str>,
    account: &Account,
    output: &OutputService,
    imap: &mut ImapService,
    smtp: &mut SmtpService,
) -> Result<()> {
    let mut msg = imap.get_msg(&uid)?;
    // Change the msg to a reply-msg.
    msg.change_to_reply(&account, all)?;
    // Apply the given attachments to the reply-msg.
    attachments_paths
        .iter()
        .for_each(|path| msg.add_attachment(path));
    debug!("found {} attachments", attachments_paths.len());
    trace!("attachments: {:#?}", attachments_paths);
    msg_interaction(output, &mut msg, imap, smtp)?;
    imap.logout()?;
    Ok(())
}

pub fn save<ImapService: ImapServiceInterface>(
    mbox: Option<&str>,
    msg: &str,
    imap: &mut ImapService,
) -> Result<()> {
    let mbox = Mbox::try_from(mbox)?;
    let mut msg = Msg::try_from(msg)?;
    msg.flags.insert(Flag::Seen);
    imap.append_msg(&mbox, &mut msg)?;
    imap.logout()?;
    Ok(())
}

pub fn search<ImapService: ImapServiceInterface>(
    page_size: Option<usize>,
    page: usize,
    query: String,
    account: &Account,
    output: &OutputService,
    imap: &mut ImapService,
) -> Result<()> {
    let page_size = page_size.unwrap_or(account.default_page_size);
    let msgs = imap.search_msgs(&query, &page_size, &page)?;
    let msgs = if let Some(ref fetches) = msgs {
        Msgs::try_from(fetches)?
    } else {
        Msgs::new()
    };
    trace!("messages: {:?}", msgs);
    output.print(msgs)?;
    imap.logout()?;
    Ok(())
}

pub fn send<ImapService: ImapServiceInterface, SmtpService: SmtpServiceInterface>(
    msg: &str,
    output: &OutputService,
    imap: &mut ImapService,
    smtp: &mut SmtpService,
) -> Result<()> {
    let msg = if atty::is(Stream::Stdin) || output.is_json() {
        msg.replace("\r", "").replace("\n", "\r\n")
    } else {
        io::stdin()
            .lock()
            .lines()
            .filter_map(|ln| ln.ok())
            .map(|ln| ln.to_string())
            .collect::<Vec<String>>()
            .join("\r\n")
    };
    let mut msg = Msg::try_from(msg.as_str())?;
    // send the message/msg
    let sendable = msg.to_sendable_msg()?;
    smtp.send(&sendable)?;
    debug!("message sent!");
    // add the message/msg to the Sent-Mailbox of the user
    msg.flags.insert(Flag::Seen);
    let mbox = Mbox::from("Sent");
    imap.append_msg(&mbox, &mut msg)?;
    imap.logout()?;
    Ok(())
}

pub fn write<ImapService: ImapServiceInterface, SmtpService: SmtpServiceInterface>(
    attachments_paths: Vec<&str>,
    account: &Account,
    output: &OutputService,
    imap: &mut ImapService,
    smtp: &mut SmtpService,
) -> Result<()> {
    let mut msg = Msg::new_with_headers(
        &account,
        Headers {
            subject: Some(String::new()),
            to: Vec::new(),
            ..Headers::default()
        },
    );
    attachments_paths
        .iter()
        .for_each(|path| msg.add_attachment(path));
    msg_interaction(output, &mut msg, imap, smtp)?;
    imap.logout()?;
    Ok(())
}