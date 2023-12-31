use keyring::Entry;

#[tokio::main]
async fn main() {
    let passwd = Entry::new("a").find_secret().await.unwrap();
    println!("passwd: {:?}", passwd);
}
