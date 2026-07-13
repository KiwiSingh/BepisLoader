# GameHub launch-hook fix (1.0.4)

- Searches both sandboxed and non-sandboxed GameHub support directories.
- Supports `environment_variables`, `environmentVariables`, and legacy `environment` settings keys.
- Handles numeric or string GameHub binding/app IDs.
- Detects `.exe` targets anywhere in Wine/Proton wrapper command lines.
- Uses valid semicolon-delimited `WINEDLLOVERRIDES` entries.
