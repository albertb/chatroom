/// A simple web-based chatroom
import chatroom/chat
import chatroom/history
import chatroom/room
import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleam/string_tree
import gleam/uri
import handles
import handles/ctx
import logging
import mist.{type Connection, type ResponseData}
import simplifile

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  // Start the history and room actors.
  let history = history.start()
  let chatroom = room.start(history)

  let assert Ok(_) =
    fn(req: Request(Connection)) -> Response(ResponseData) {
      logging.log(
        logging.Debug,
        "Request "
          <> uri.to_string(request.to_uri(req))
          <> " from: "
          <> string.inspect(mist.get_client_info(req.body)),
      )
      case request.path_segments(req) {
        // The empty path serves home_page.html from disk.
        [] -> {
          let content =
            simplifile.read("web/home.html")
            |> result.unwrap("failed to read home_page.html")

          response.new(200)
          |> response.set_body(mist.Bytes(bytes_tree.from_string(content)))
        }

        ["chat"] -> {
          case mist.read_body(req, 1024) {
            Error(_) ->
              response.new(500)
              |> response.set_body(mist.Bytes(bytes_tree.new()))
            Ok(body) -> {
              // The form fields are URL-encoded, extract the value of the "sender" field.
              let #(_, sender) =
                bit_array.to_string(body.body)
                |> result.map(fn(content) { string.split_once(content, "=") })
                |> result.flatten()
                |> result.unwrap(#("_", "guest"))

              // Make sure the sender isn't empty.
              let sender = case string.length(sender) {
                n if n > 0 -> sender
                _ -> "guest"
              }

              response.new(200)
              |> response.set_body(
                mist.Bytes(
                  bytes_tree.from_string(render_chat_form(sender, False)),
                ),
              )
            }
          }
        }

        // The /ws path is the websocket that the web page connects to.
        ["ws"] -> {
          mist.websocket(
            request: req,
            on_init: fn(_conn) {
              // Create a new client, and register it with the room.
              let client = room.RoomClient(subject: process.new_subject())
              process.send(chatroom, room.Register(client))

              // Create a selector that listens for messages sent to the client.
              let selector =
                process.select(process.new_selector(), client.subject)

              #(client, Some(selector))
            },
            on_close: fn(client) {
              // Unregister clients when they close the websocket connection.
              process.send(chatroom, room.Unregister(client))
            },
            handler: fn(client, message, conn) {
              case message {
                mist.Text(text) -> {
                  // This is a text message received from the web page.
                  logging.log(logging.Debug, "Websocket text: " <> text)

                  // The HTMX websocket extension serializes the form fields into a JSON string.
                  // We extract just the relevant fields here.
                  let decoder = {
                    use sender <- decode.field("sender", decode.string)
                    use content <- decode.field("content", decode.string)
                    decode.success(#(sender, content))
                  }
                  let assert Ok(#(sender, content)) =
                    json.parse(from: text, using: decoder)

                  // Publish the message to the room actor.
                  chatroom |> process.send(room.Publish(sender, content))

                  mist.continue(client)
                }

                mist.Custom(chat.ChatMessage(sender, content)) -> {
                  // This is a ChatMessage from the room actor.
                  logging.log(
                    logging.Debug,
                    "Websocket chat message from " <> sender <> ": " <> content,
                  )

                  // Render the HTML to swap onto the page.
                  let assert Ok(_) =
                    mist.send_text_frame(conn, render_message(sender, content))
                  let assert Ok(_) =
                    mist.send_text_frame(conn, render_chat_form(sender, True))

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
    |> mist.bind("0.0.0.0")
    |> mist.port(9999)
    |> mist.start

  process.sleep_forever()
}

/// Renders the chat from using the specified name.
/// When returing the form via the websocket, oob should be true for HTMX to swap out the existing form.
fn render_chat_form(sender: String, oob: Bool) -> String {
  let assert Ok(source) = simplifile.read("web/chat.html")
  let assert Ok(template) = handles.prepare(source)
  let assert Ok(rendered) =
    handles.run(
      template,
      ctx.Dict([
        ctx.Prop("sender", ctx.Str(sender)),
        ctx.Prop("oob", ctx.Bool(oob)),
      ]),
      [],
    )
  string_tree.to_string(rendered)
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
