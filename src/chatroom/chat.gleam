/// The message broadcast by the room actor to registered clients.
pub type ChatMessage {
  ChatMessage(sender: String, content: String)
}
