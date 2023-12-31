use notify_rust::{error::Result, Notification};

#[tokio::main]
async fn main() -> Result<()> {
    Notification::new()
        .summary("Firefox News")
        .body("This will almost look like a real firefox notification.")
        .show_async()
        .await?;

    Ok(())
}
