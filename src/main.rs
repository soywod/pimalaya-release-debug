use notify_rust::Notification;

fn main() {
    Notification::new().summary("coucou").show().unwrap();
}
