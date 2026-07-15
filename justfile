set shell := ["zsh", "-cu"]

default:
    @just --list

# MoonBit製host/client/Workerをrelease JSとして事前ビルドする
build-worker:
    moon build --target js --release
    mkdir -p dist
    cp _build/js/release/build/examples/mix_worker/mix_worker.js dist/mayo_worker.js
    cp _build/js/release/build/worker/worker.js dist/bench_worker.js
    cp _build/js/release/build/tests/client/client.js dist/client_test.js
    cp _build/js/release/build/examples/host/host.js dist/mayo_example.js
    cp _build/js/release/build/examples/sync_guest/sync_guest.js dist/sync_guest.js
    cp _build/js/release/build/examples/sync_host/sync_host.js dist/sync_host.js
    cp _build/js/release/build/examples/wasm_host/wasm_host.js dist/wasm_host.js
    cp _build/js/release/build/bench/mayo/mayo.js dist/mayo_bench.js
    mkdir -p dist/web
    cp _build/js/release/build/examples/web/web.js dist/web/mayo_web.js
    cp _build/js/release/build/examples/mix_worker/mix_worker.js dist/web/mayo_worker.js
    cp _build/js/release/build/examples/sync_guest/sync_guest.js dist/web/sync_guest.js
    cp examples/web/index.html dist/web/index.html

# MoonBit guestをWasmへビルドし、汎用JS Worker glueと配置する
build-wasm:
    moon build examples/wasm_guest --target wasm --release
    mkdir -p dist
    cp _build/wasm/release/build/examples/wasm_guest/wasm_guest.wasm dist/wasm_guest.wasm
    cp wasm/guest_runtime.js dist/mayo_wasm_guest.js
    mkdir -p dist/web
    cp _build/wasm/release/build/examples/wasm_guest/wasm_guest.wasm dist/web/wasm_guest.wasm
    cp wasm/guest_runtime.js dist/web/mayo_wasm_guest.js

# C と Rust の比較用ベンチマークをビルドする
build-native:
    mkdir -p dist
    cc -O3 -std=c11 -Wall -Wextra -Werror -pthread native/c/bench.c -o dist/c-bench
    cargo build --release --manifest-path native/rust/Cargo.toml
    cp native/rust/target/release/rust-bench dist/rust-bench

# 全 backend をビルドする
build: build-worker build-wasm build-native

# MoonBit と Deno のテストを実行する
test: build
    moon test --target js
    deno run --allow-read dist/client_test.js
    deno run --allow-read dist/sync_host.js
    deno run --allow-read dist/wasm_host.js
    cargo test --release --manifest-path native/rust/Cargo.toml
    deno test --allow-read --allow-run tests bench
    pnpm exec playwright test

# 型・フォーマット・lint・テストをまとめて検証する
check: build
    moon check --target js
    moon check --target wasm
    moon test --target js
    deno run --allow-read dist/client_test.js
    deno run --allow-read dist/sync_host.js
    deno run --allow-read dist/wasm_host.js
    cargo fmt --manifest-path native/rust/Cargo.toml -- --check
    cargo clippy --release --manifest-path native/rust/Cargo.toml -- -D warnings
    deno fmt --check
    deno lint
    deno test --allow-read --allow-run tests bench
    pnpm exec playwright test

# ソースを整形する
fmt:
    moon fmt
    cargo fmt --manifest-path native/rust/Cargo.toml
    deno fmt
    just --fmt

# Worker 起動時間と Mutex 競合処理を測定する
bench workers="4" iterations="50000" samples="30" rounds="10": build
    deno run --allow-read bench/benchmark.ts --workers {{ workers }} --iterations {{ iterations }} --samples {{ samples }} --rounds {{ rounds }}

# MoonBit製host APIとサンプルkernelを実行する
example: build-worker
    deno run --allow-read dist/mayo_example.js

# 別コンパイルした型付きMoonBit host/guestをDenoで実行する
example-sync: build-worker
    deno run --allow-read dist/sync_host.js

# MoonBit/JS hostからMoonBit/Wasm guestをDenoで実行する
example-wasm: build-worker build-wasm
    deno run --allow-read dist/wasm_host.js

# COOP/COEP付きでMoonBit製Webサンプルを配信する
serve-web: build-worker build-wasm
    deno run --allow-read --allow-net tests/web/server.ts

# 実ブラウザでMoonBit hostとWorkerの共有メモリ処理を検証する
test-web:
    pnpm exec playwright test

# 機械可読な JSON で測定する
bench-json workers="4" iterations="50000" samples="30" rounds="10": build
    deno run --allow-read bench/benchmark.ts --workers {{ workers }} --iterations {{ iterations }} --samples {{ samples }} --rounds {{ rounds }} --json

# 常駐poolをC pthread / mmap process / Rust / Rayon / MoonBitで比較する
compare workers="4": build
    deno run --allow-read --allow-run bench/compare.ts --workers {{ workers }}

# 短縮条件で常駐poolを比較する
compare-quick workers="4": build
    deno run --allow-read --allow-run bench/compare.ts --workers {{ workers }} --quick

# 常駐pool比較をJSONで出力する
compare-json workers="4": build
    deno run --allow-read --allow-run bench/compare.ts --workers {{ workers }} --json
