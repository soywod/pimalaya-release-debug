use keyring::Entry;

#[tokio::main]
async fn main() {
    let passwd = Entry::new("a", "b").unwrap().get_password().unwrap();
    println!("passwd: {:?}", passwd);
}
