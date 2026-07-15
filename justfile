set shell := ["bash", "-cu"]

default:
    @just --list

# kernel schemaからMoonBitのHost/Guest descriptorを生成する
generate:
    deno run --allow-read --allow-write tools/mayo_gen.ts examples/mix_kernel/mayo.kernel.json examples/mix_kernel/kernel.generated.mbt
    deno run --allow-read --allow-write tools/mayo_gen.ts tests/generated_contract/mayo.kernel.json tests/generated_contract/contract.generated.mbt
    moon fmt

# checked-in descriptorがschemaと一致することを検証する
check-generated:
    deno run --allow-read tools/mayo_gen.ts examples/mix_kernel/mayo.kernel.json examples/mix_kernel/kernel.generated.mbt --check
    deno run --allow-read tools/mayo_gen.ts tests/generated_contract/mayo.kernel.json tests/generated_contract/contract.generated.mbt --check
    deno run --allow-read tools/mayo_build.ts mayo.build.json --check

# descriptor生成からguest artifact配置までをbuild契約に従って実行する
build-kernel config="mayo.build.json":
    deno run --allow-read --allow-write --allow-run tools/mayo_build.ts {{ config }}

# MoonBit製host/client/Workerをrelease JSとして事前ビルドする
build-worker:
    moon build --target js --release
    mkdir -p dist
    cp _build/js/release/build/examples/mix_worker/mix_worker.js dist/mayo_worker.js
    cp _build/js/release/build/worker/worker.js dist/bench_worker.js
    cp _build/js/release/build/tests/client/client.js dist/client_test.js
    cp _build/js/release/build/examples/host/host.js dist/mayo_example.js
    cp _build/js/release/build/examples/scope_host/scope_host.js dist/mayo_scope_example.js
    cp _build/js/release/build/examples/sync_guest/sync_guest.js dist/json_guest.js
    cp _build/js/release/build/examples/sync_host/sync_host.js dist/json_host.js
    cp _build/js/release/build/examples/wasm_host/wasm_host.js dist/wasm_host.js
    cp _build/js/release/build/examples/image_worker/image_worker.js dist/image_worker.js
    cp _build/js/release/build/examples/image_host/image_host.js dist/image_example.js
    cp _build/js/release/build/bench/mayo/mayo.js dist/mayo_bench.js
    mkdir -p dist/web
    cp _build/js/release/build/examples/web/web.js dist/web/mayo_web.js
    cp _build/js/release/build/examples/mix_worker/mix_worker.js dist/web/mayo_worker.js
    cp _build/js/release/build/examples/sync_guest/sync_guest.js dist/web/json_guest.js
    cp examples/web/index.html dist/web/index.html

# MoonBit kernelをshared-memory Wasmへビルドし、汎用JS Worker glueと配置する
build-wasm:
    moon build examples/wasm_guest --target wasm --release
    mkdir -p dist
    cp _build/wasm/release/build/examples/wasm_guest/wasm_guest.wasm dist/wasm_guest.wasm
    cp wasm/guest_runtime.js dist/mayo_wasm_kernel.js
    mkdir -p dist/web
    cp dist/wasm_guest.wasm dist/web/wasm_guest.wasm
    cp wasm/guest_runtime.js dist/web/mayo_wasm_kernel.js

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
    deno run --allow-read dist/json_host.js
    deno run --allow-read dist/wasm_host.js
    deno run --allow-read dist/image_example.js
    cargo test --release --manifest-path native/rust/Cargo.toml
    deno test --allow-read --allow-run tests bench tools
    pnpm exec playwright test

# 型・フォーマット・lint・テストをまとめて検証する
check: build
    moon check --target js
    moon check --target wasm
    moon test --target js
    deno run --allow-read dist/client_test.js
    deno run --allow-read dist/json_host.js
    deno run --allow-read dist/wasm_host.js
    deno run --allow-read dist/image_example.js
    cargo fmt --manifest-path native/rust/Cargo.toml -- --check
    cargo clippy --release --manifest-path native/rust/Cargo.toml -- -D warnings
    deno fmt --check
    deno lint
    deno test --allow-read --allow-run tests bench tools
    pnpm exec playwright test

# Browser以外のCI checkを1つの再現可能なentry pointで実行する
ci-core: build
    just check-generated
    moon check --target js
    moon check --target wasm
    moon test --target js
    deno run --allow-read dist/client_test.js
    deno run --allow-read dist/json_host.js
    deno run --allow-read dist/wasm_host.js
    deno run --allow-read dist/image_example.js
    cargo test --release --manifest-path native/rust/Cargo.toml
    cargo fmt --manifest-path native/rust/Cargo.toml -- --check
    cargo clippy --release --manifest-path native/rust/Cargo.toml -- -D warnings
    deno fmt --check
    deno lint
    deno test --allow-read --allow-run tests bench tools

# Playwright containerでWeb integrationだけを独立実行する
ci-web: build-worker build-wasm
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

# ThreadPool::scopeによる構造化並行性のサンプルを実行する
example-scope: build-worker
    deno run --allow-read dist/mayo_scope_example.js

# optional JSON compatibility host/guestをDenoで実行する
example-json: build-worker
    deno run --allow-read dist/json_host.js

# MoonBit/JS hostからMoonBit/Wasm guestをDenoで実行する
example-wasm: build-worker build-wasm
    deno run --allow-read dist/wasm_host.js

# 共有RGB画像をグレースケール化し、Sobel edge detectionを並列実行する
example-image: build-worker
    deno run --allow-read dist/image_example.js

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

# 要素数×計算量ごとのbreak-even matrixを実測する
break-even workers="4": build
    deno run --allow-read --allow-run bench/break_even.ts --workers {{ workers }}

# CIや開発中に短縮matrixを実測する
break-even-quick workers="4": build
    deno run --allow-read --allow-run bench/break_even.ts --workers {{ workers }} --quick

# break-even matrixを機械可読JSONで出力する
break-even-json workers="4": build
    deno run --allow-read --allow-run bench/break_even.ts --workers {{ workers }} --json

# 同一runner上のpthread/Rayon比と絶対budgetで性能の桁落ちを検知する
performance-regression workers="4" output="dist/performance-report.json": build
    deno run --allow-read --allow-write --allow-run bench/regression.ts --workers {{ workers }} --output {{ output }}

# 公開対象file、全非browser check、性能budgetを検証し、0.1.0 archiveを生成する
release-check: ci-core performance-regression
    moon package --list --frozen
