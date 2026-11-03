# RAG Chat App — Flutter Client

A responsive Flutter chat client for a personal document question-answering assistant. The app is designed for Android phones and Windows desktop and communicates with the Python RAG API over HTTP.

## Features

- Responsive chat layout: sidebar-style conversation navigation on wide screens and a mobile drawer/navigation layout on narrow screens.
- New conversations, saved recent chats, reopening conversations, and deleting saved conversations.
- Conversation history stored locally on the device using `shared_preferences`.
- Sends the current question and, when present, a `session_id` to the RAG API.
- Renders assistant responses as Markdown using `flutter_markdown_plus`.
- Shows source metadata returned by the backend when available, including source title and page.
- Shows loading/error states for API requests and scrolls the conversation toward the latest message.

Conversation persistence is local to each installation. It is not account-based cloud synchronization, and phone history is not automatically shared with the Windows app.

## Requirements

- Flutter SDK compatible with the Dart SDK constraint in `pubspec.yaml`.
- Android SDK/device or emulator for Android builds.
- For Windows desktop builds, Windows plus Visual Studio with the **Desktop development with C++** workload.
- A reachable Month4-2 API endpoint.

## Get started

From the Flutter project directory:

~~~powershell
flutter pub get
flutter devices
~~~

Run on a connected Android device/emulator:

~~~powershell
flutter run -d DEVICE_ID
~~~

Run on Windows:

~~~powershell
flutter run -d windows
~~~

Build release artifacts:

~~~powershell
flutter build apk --release
flutter build windows --release
~~~

Replace `DEVICE_ID` with the identifier shown by `flutter devices`. Windows desktop build support must be enabled in the local Flutter installation, and its Visual Studio C++ tools must be installed.

## Connect to the backend

`lib/chat_service.dart` contains the current API endpoint setting. Configure it to the `/ask` route of a backend you control. The README intentionally does not publish the endpoint currently in the source file.

For local desktop development, the backend Compose setup defaults to a local API binding at:

~~~text
http://127.0.0.1:8080/ask
~~~

The phone cannot use `127.0.0.1` to reach the computer. An Android emulator, physical phone, or remote build needs a URL reachable from that device. For local testing, use an appropriate emulator/host-network route or a protected development tunnel. Do not expose an unauthenticated backend to the public internet.

Before publishing this repository, replace the hardcoded endpoint with an environment/build configuration mechanism such as a Dart compile-time define. Never ship the backend's long-lived `RAG_API_KEYS` secret inside the Flutter client; secrets embedded in a mobile or desktop application can be extracted. Use a proper user/session authentication design for a public client.

## Request and response behavior

The client sends a JSON request containing:

- `question` — the user's text.
- `session_id` — included when continuing an existing server session.

The response parser reads `answer`, `session_id`, retrieval metadata, and a list of source references. Each source can have a title and optional page. The UI can display only metadata that the API actually returns; a missing page number generally needs to be fixed in the ingestion/index metadata rather than in Flutter.

The chat history saved by `shared_preferences` is local app data. It can be deleted from the conversation list or cleared by uninstalling/resetting the app data. It is not a secure vault for secrets.

## Main files

~~~text
lib/
├── main.dart          # Theme, responsive layout, message/conversation models, local persistence, chat UI
└── chat_service.dart  # HTTP client and API response/source parsing
~~~

Other folders provide platform runners and configuration. The repository includes several Flutter platform folders, but the usage instructions above focus on Android and Windows, the platforms used for this app.

## Dependencies

- `http` — sends requests to the backend.
- `shared_preferences` — stores local conversation history.
- `flutter_markdown_plus` — renders Markdown in assistant messages.
- `cupertino_icons` — icon assets.
- `flutter_lints` and `flutter_test` — development tooling.

## Troubleshooting

### “Couldn’t reach the RAG server”

1. Confirm the backend containers are running and healthy.
2. Confirm the app's endpoint points to `/ask` on the currently running API/proxy.
3. On a phone, do not use the computer's `localhost`/`127.0.0.1`; use a reachable development address.
4. Check that the selected tunnel is running and its current address matches the configured endpoint.
5. Check backend logs for dependency, authentication, or timeout errors. The UI message alone may not identify the server-side cause.

### Answers show no page numbers or sources

The app parses the `sources` list and optional `page` field. If those are empty in the API response, confirm the ingestion pipeline saved source title/page metadata and that retrieval returns it. Flutter cannot infer the original page when the backend did not return that data.

### Windows target unavailable

Run `flutter doctor -v` and install Visual Studio's **Desktop development with C++** workload if Flutter reports a missing Windows toolchain.

## Privacy and release checklist

- Set the API endpoint using local/build configuration before publishing.
- Never include API keys, database credentials, private tunnel addresses, user documents, or private chat transcripts in the source, screenshots, or README.
- Explain to users that chat history is stored locally on their device.
- Configure TLS and server-side authentication before connecting to a public backend.
- Run `flutter analyze` and the app manually on each target before calling a release verified.

## License

No license is specified here. Add a license file before inviting reuse or accepting external contributions.
