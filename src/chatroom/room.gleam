import chatroom/chat
import chatroom/history
import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import gleam/string
import logging

/// The client actor that listens for chat messages.
pub type RoomClient {
  RoomClient(subject: process.Subject(chat.ChatMessage))
}

/// The state of the room is the list of its registered clients.
pub type RoomState {
  RoomState(
    history: process.Subject(history.HistoryMessage),
    clients: List(RoomClient),
  )
}

/// The messages that clients send to the room actor.
pub type RoomMessage {
  Publish(sender: String, content: String)
  Register(client: RoomClient)
  Unregister(client: RoomClient)
}

/// Start the room actor and return its subject.
pub fn start(
  history: process.Subject(history.HistoryMessage),
) -> process.Subject(RoomMessage) {
  let assert Ok(chatroom) =
    actor.new(RoomState(history, []))
    |> actor.on_message(chatroom_loop)
    |> actor.start
  chatroom.data
}

/// The main loop for the room actor.
fn chatroom_loop(state: RoomState, message: RoomMessage) {
  case message {
    Publish(sender, content) -> {
      logging.log(logging.Info, "Publish [" <> sender <> "]: " <> content)

      let msg = chat.ChatMessage(sender, content)
      state.clients |> list.each(fn(c) { process.send(c.subject, msg) })
      state.history |> actor.send(history.Append(msg))
      state |> actor.continue
    }

    Register(client) -> {
      logging.log(logging.Debug, "Register: " <> string.inspect(client))
      state.history |> actor.send(history.GetRecent(client.subject))
      RoomState(state.history, [client, ..state.clients]) |> actor.continue
    }

    Unregister(client) -> {
      logging.log(logging.Debug, "Unregister: " <> string.inspect(client))
      RoomState(
        state.history,
        state.clients |> list.filter(fn(c) { c != client }),
      )
      |> actor.continue
    }
  }
}
