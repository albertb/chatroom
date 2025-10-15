import chatroom/chat
import gleam/erlang/process
import gleam/list
import gleam/otp/actor

pub type HistoryMessage {
  Append(chat.ChatMessage)
  GetRecent(reply_with: process.Subject(chat.ChatMessage))
}

pub fn start() -> process.Subject(HistoryMessage) {
  let assert Ok(history) =
    actor.new([])
    |> actor.on_message(history_loop)
    |> actor.start
  history.data
}

fn history_loop(state: List(chat.ChatMessage), message: HistoryMessage) {
  case message {
    Append(msg) -> {
      // Append the message to the history.
      actor.continue([msg, ..state])
    }

    GetRecent(reply_with) -> {
      // Publish the recent messages to the requesting client.
      list.reverse(state) |> list.each(fn(m) { process.send(reply_with, m) })
      actor.continue(state)
    }
  }
}
