#!/usr/bin/env bash
set -euo pipefail

# Run on the signing Mac. Pass --no-codesign to validate an unsigned archive.
# Rebuild Rust as well: reusing an old static library would still persist
# biometric-session access tokens in the legacy local configuration.
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iOS builds require macOS and Xcode." >&2
  exit 1
fi

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
cargo build --features flutter,hwcodec --release --target aarch64-apple-ios --lib

cd flutter
flutter pub get
flutter test --no-pub test/biometric_login_test.dart \
  test/login_session_status_test.dart test/login_response_test.dart
flutter build ipa --release "$@"
