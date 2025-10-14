/// A simple web-based chatroom
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/string_tree
import handles
import handles/ctx
import logging
import mist.{type Connection, type ResponseData}
import simplifile

/// The message broadcast by the room actor to registered clients.
pub type ChatMessage {
  ChatMessage(sender: String, content: String)
}

/// The client actor that listens for chat messages.
pub type RoomClient {
  RoomClient(subject: process.Subject(ChatMessage))
}

/// The state of the room is the list of its registered clients.
pub type RoomState {
  RoomState(clients: List(RoomClient))
}

/// The messages that clients send to the room actor.
pub type RoomMessage {
  Publish(sender: String, content: String)
  Register(client: RoomClient)
  Unregister(client: RoomClient)
}

/// The main loop for the room actor.
fn chatroom_loop(state: RoomState, message: RoomMessage) {
  case message {
    Publish(sender, content) -> {
      logging.log(logging.Info, "Publish from " <> sender <> ": " <> content)
      state.clients
      |> list.each(fn(c) {
        process.send(c.subject, ChatMessage(sender, content))
      })
      state |> actor.continue
    }

    Register(client) -> {
      logging.log(logging.Debug, "Register: " <> string.inspect(client))
      RoomState([client, ..state.clients]) |> actor.continue
    }

    Unregister(client) -> {
      logging.log(logging.Debug, "Unregister: " <> string.inspect(client))
      RoomState(list.filter(state.clients, fn(c) { c != client }))
      |> actor.continue
    }
  }
}

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  // Start the room actor.
  let assert Ok(chatroom) =
    actor.new(RoomState([]))
    |> actor.on_message(chatroom_loop)
    |> actor.start

  let assert Ok(_) =
    fn(req: Request(Connection)) -> Response(ResponseData) {
      logging.log(
        logging.Debug,
        "Request from: " <> string.inspect(mist.get_client_info(req.body)),
      )
      case request.path_segments(req) {
        // The empty path serves home_page.html from disk.
        [] -> {
          let content =
            simplifile.read("web/home_page.html")
            |> result.unwrap("failed to read home_page.html")

          response.new(200)
          |> response.set_body(mist.Bytes(bytes_tree.from_string(content)))
        }

        // The /ws path is the websocket that the web page connects to.
        ["ws"] -> {
          mist.websocket(
            request: req,
            on_init: fn(_conn) {
              // Create a new client, and register it with the room.
              let client = RoomClient(subject: process.new_subject())
              process.send(chatroom.data, Register(client))

              // Create a selector that listens to messages sent to the client.
              let selector =
                process.select(process.new_selector(), client.subject)

              #(client, Some(selector))
            },
            on_close: fn(client) {
              // Unregister clients when they close the websocket connection.
              process.send(chatroom.data, Unregister(client))
            },
            handler: fn(client, message, conn) {
              case message {
                mist.Text(text) -> {
                  // This is a text message received from the web page.
                  logging.log(logging.Debug, "Websocket text: " <> text)

                  // The HTMX websocket extension serializes the from fields into a JSON string.
                  // We extract just the relevant fields here.
                  let decoder = {
                    use sender <- decode.field("sender", decode.string)
                    use content <- decode.field("content", decode.string)
                    decode.success(#(sender, content))
                  }
                  let assert Ok(#(sender, content)) =
                    json.parse(from: text, using: decoder)

                  // Publish the message to the room actor.
                  chatroom.data |> process.send(Publish(sender, content))
                  mist.continue(client)
                }

                mist.Custom(ChatMessage(sender, content)) -> {
                  // This is a ChatMessage from the room actor.
                  logging.log(
                    logging.Debug,
                    "Websocket chat message from " <> sender <> ": " <> content,
                  )

                  // Render the HTML to swap onto the page.
                  let text = render_message(sender, content)

                  let assert Ok(_) = mist.send_text_frame(conn, text)
                  mist.continue(client)
                }

                _ -> {
                  // Ignore other types of messages.
                  mist.continue(client)
                }
              }
            },
          )
        }

        // Return a 404 error for requests that don't match either paths.
        _ ->
          response.new(404)
          |> response.set_body(mist.Bytes(bytes_tree.new()))
      }
    }
    |> mist.new
    |> mist.port(9999)
    |> mist.start

  process.sleep_forever()
}

/// Renders a message bubble to be added to the web page.
fn render_message(sender: String, content: String) -> String {
  let assert Ok(source) = simplifile.read("web/message.html")
  let assert Ok(template) = handles.prepare(source)
  let assert Ok(rendered) =
    handles.run(
      template,
      ctx.Dict([
        ctx.Prop("sender", ctx.Str(sender)),
        ctx.Prop("content", ctx.Str(content)),
      ]),
      [],
    )
  string_tree.to_string(rendered)
}
