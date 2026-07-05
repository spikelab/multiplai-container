#!/bin/bash
# apple-containers-experiment.sh — Compare Apple Containers vs OrbStack (Docker)
#
# Runs a series of tests building and running the Claude Code Multiplai container
# with both runtimes and produces a side-by-side comparison report.
#
# Prerequisites:
#   - macOS 26 (Tahoe)
#   - Homebrew installed
#   - OrbStack installed and running (provides `docker` CLI)
#
# Usage:
#   cd container && ./apple-containers-experiment.sh
#
# The script is incremental — each phase can be run independently:
#   ./apple-containers-experiment.sh setup     # Install Apple Containers only
#   ./apple-containers-experiment.sh build     # Build images with both runtimes
#   ./apple-containers-experiment.sh test      # Run comparison tests
#   ./apple-containers-experiment.sh report    # Show results
#   ./apple-containers-experiment.sh all       # Full run (default)
#   ./apple-containers-experiment.sh teardown  # Clean up images and containers

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPORT_DIR="$SCRIPT_DIR/.experiment-results"
REPORT_FILE="$REPORT_DIR/comparison-report.md"
TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S)

# Image names
DOCKER_IMAGE="claude-multiplai:local"
APPLE_IMAGE="claude-multiplai-apple"
# Simplified Dockerfile for the experiment (arm64-native, minimal)
APPLE_DOCKERFILE="$REPORT_DIR/Dockerfile.apple-arm64"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[info]${NC} $*"; }
ok()    { echo -e "${GREEN}[ok]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
err()   { echo -e "${RED}[error]${NC} $*"; }
phase() { echo -e "\n${BOLD}━━━ $* ━━━${NC}\n"; }

mkdir -p "$REPORT_DIR"

# ─── Utility functions ───────────────────────────────────────────────

time_cmd() {
    # Returns wall-clock seconds (to millisecond precision)
    local start end
    start=$(date +%s.%N 2>/dev/null || python3 -c 'import time; print(f"{time.time():.3f}")')
    "$@"
    end=$(date +%s.%N 2>/dev/null || python3 -c 'import time; print(f"{time.time():.3f}")')
    python3 -c "print(f'{$end - $start:.3f}')"
}

record() {
    # Append a key=value to the results CSV
    local runtime="$1" metric="$2" value="$3" unit="${4:-}"
    echo "$runtime,$metric,$value,$unit" >> "$REPORT_DIR/results.csv"
}

# ─── Phase: Setup ────────────────────────────────────────────────────

do_setup() {
    phase "Phase 1: Setup & Prerequisites"

    # Check macOS version
    local macos_version
    macos_version=$(sw_vers -productVersion)
    local macos_major
    macos_major=$(echo "$macos_version" | cut -d. -f1)
    info "macOS version: $macos_version"
    if [[ "$macos_major" -lt 26 ]]; then
        err "macOS 26 (Tahoe) required for Apple Containers. You're on $macos_version."
        exit 1
    fi
    ok "macOS 26 Tahoe confirmed"

    # Check architecture
    local arch
    arch=$(uname -m)
    info "Architecture: $arch"
    if [[ "$arch" != "arm64" ]]; then
        err "Apple Silicon (arm64) required. Got: $arch"
        exit 1
    fi
    ok "Apple Silicon confirmed"

    # Check memory
    local mem_gb
    mem_gb=$(sysctl -n hw.memsize | awk '{printf "%.0f", $1/1073741824}')
    info "System memory: ${mem_gb}GB"
    record "system" "memory_gb" "$mem_gb" "GB"
    record "system" "macos_version" "$macos_version"
    record "system" "arch" "$arch"
    record "system" "chip" "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown')"

    # Check OrbStack/Docker
    if command -v docker &>/dev/null; then
        local docker_ver
        docker_ver=$(docker --version)
        info "Docker CLI: $docker_ver"
        if docker info 2>/dev/null | grep -q "OrbStack"; then
            ok "OrbStack detected as Docker backend"
            record "system" "docker_backend" "OrbStack"
        else
            warn "Docker detected but not OrbStack — results may differ from OrbStack benchmarks"
            record "system" "docker_backend" "$(docker info 2>/dev/null | grep 'Server Version' | awk '{print $NF}')"
        fi
    else
        err "Docker CLI not found. Install OrbStack first."
        exit 1
    fi

    # Install Apple Containers CLI
    if command -v container &>/dev/null; then
        local container_ver
        container_ver=$(container --version 2>&1 || echo "unknown")
        ok "Apple Containers CLI already installed: $container_ver"
        record "system" "apple_container_version" "$container_ver"
    else
        info "Installing Apple Containers CLI via Homebrew..."
        if ! command -v brew &>/dev/null; then
            err "Homebrew not found. Install it first: https://brew.sh"
            exit 1
        fi
        brew install container
        ok "Apple Containers CLI installed: $(container --version 2>&1 || echo 'unknown')"
        record "system" "apple_container_version" "$(container --version 2>&1 || echo 'unknown')"
    fi

    # Start Apple Containers system service
    info "Ensuring Apple Containers system service is running..."
    if container system info &>/dev/null 2>&1; then
        ok "Apple Containers system service already running"
    else
        info "Starting Apple Containers system service..."
        container system start
        # Wait for it to be ready
        local retries=10
        while ! container system info &>/dev/null 2>&1 && [[ $retries -gt 0 ]]; do
            sleep 2
            retries=$((retries - 1))
        done
        if container system info &>/dev/null 2>&1; then
            ok "Apple Containers system service started"
        else
            err "Failed to start Apple Containers system service."
            echo "  Try manually: container system start"
            echo "  Then check: container system info"
            echo ""
            echo "  IMPORTANT: macOS may prompt you to allow Local Network access."
            echo "  Go to System Settings > Privacy & Security > Local Network"
            echo "  and enable access for 'container' and 'container-runtime-linux'."
            exit 1
        fi
    fi

    # Register as brew service for auto-start
    if ! brew services list 2>/dev/null | grep -q "container.*started"; then
        info "Registering Apple Containers as brew service for auto-start..."
        brew services start container 2>/dev/null || warn "Could not register as brew service (non-fatal)"
    fi

    echo ""
    ok "Setup complete. Both runtimes ready."
    echo ""
    echo "  ┌─────────────────────────────────────────────┐"
    echo "  │  IMPORTANT: Local Network Firewall          │"
    echo "  │                                             │"
    echo "  │  If container builds fail with network      │"
    echo "  │  errors, go to:                             │"
    echo "  │  System Settings > Privacy & Security >     │"
    echo "  │  Local Network                              │"
    echo "  │                                             │"
    echo "  │  Enable access for:                         │"
    echo "  │  • container (client)                       │"
    echo "  │  • container-runtime-linux                  │"
    echo "  └─────────────────────────────────────────────┘"
    echo ""
}

# ─── Phase: Build ────────────────────────────────────────────────────

do_build() {
    phase "Phase 2: Build Images"

    # Source .env for build args
    if [ -f "$KIT_ROOT/.env" ]; then
        # shellcheck disable=SC1091
        source "$KIT_ROOT/.env"
    elif [ -f "$SCRIPT_DIR/.env" ]; then
        # shellcheck disable=SC1091
        source "$SCRIPT_DIR/.env"
    else
        warn "No .env found — using defaults for build args"
    fi

    WORKSPACE=$(eval echo "${WORKSPACE:-/workspace}")
    HOST_UID="${HOST_UID:-$(id -u)}"
    HOST_GID="${HOST_GID:-$(id -g)}"
    SSH_BUILD_USER="${SSH_BUILD_USER:-$USER}"

    # --- Build with OrbStack (Docker) ---
    info "Building image with OrbStack (Docker)..."
    info "  Image: $DOCKER_IMAGE"
    info "  Platform: linux/amd64 (OrbStack default with Rosetta)"

    local docker_build_start docker_build_end docker_build_time
    docker_build_start=$(date +%s)

    docker build \
        --build-arg HOST_UID="$HOST_UID" \
        --build-arg HOST_GID="$HOST_GID" \
        --build-arg WORKSPACE="$WORKSPACE" \
        --build-arg SSH_BUILD_USER="$SSH_BUILD_USER" \
        -t "$DOCKER_IMAGE" \
        "$SCRIPT_DIR" 2>&1 | tee "$REPORT_DIR/docker-build.log"

    docker_build_end=$(date +%s)
    docker_build_time=$((docker_build_end - docker_build_start))
    ok "Docker build complete: ${docker_build_time}s"
    record "docker" "build_time" "$docker_build_time" "seconds"

    local docker_image_size
    docker_image_size=$(docker image inspect "$DOCKER_IMAGE" --format '{{.Size}}' | awk '{printf "%.0f", $1/1048576}')
    record "docker" "image_size" "$docker_image_size" "MB"
    info "Docker image size: ${docker_image_size}MB"

    # --- Build with Apple Containers ---
    # Apple Containers defaults to the host architecture (arm64).
    # The existing Dockerfile should work — `container build` supports Dockerfiles.
    # The nodesource setup_22.x script uses dpkg --print-architecture which will
    # return arm64 natively, so it should fetch arm64 Node.js.
    info "Building image with Apple Containers..."
    info "  Image: $APPLE_IMAGE"
    info "  Platform: linux/arm64 (native Apple Silicon)"

    local apple_build_start apple_build_end apple_build_time
    apple_build_start=$(date +%s)

    # Apple Containers uses `container build` with similar syntax to docker build.
    # Key differences:
    #   - Image name uses --tag (same as docker)
    #   - Build args use --build-arg (same as docker)
    #   - Context path is the last argument (same as docker)
    container build \
        --tag "$APPLE_IMAGE" \
        --build-arg HOST_UID="$HOST_UID" \
        --build-arg HOST_GID="$HOST_GID" \
        --build-arg WORKSPACE="$WORKSPACE" \
        --build-arg SSH_BUILD_USER="$SSH_BUILD_USER" \
        --file "$SCRIPT_DIR/Dockerfile" \
        "$SCRIPT_DIR" 2>&1 | tee "$REPORT_DIR/apple-build.log"

    apple_build_end=$(date +%s)
    apple_build_time=$((apple_build_end - apple_build_start))
    ok "Apple Containers build complete: ${apple_build_time}s"
    record "apple" "build_time" "$apple_build_time" "seconds"

    # Image size (apple containers)
    local apple_image_size
    apple_image_size=$(container image list 2>/dev/null | grep "$APPLE_IMAGE" | awk '{print $NF}' || echo "unknown")
    record "apple" "image_size" "$apple_image_size" "MB"
    info "Apple Containers image size: ${apple_image_size}"

    echo ""
    ok "Both images built."
    echo "  Docker:  ${docker_build_time}s (${docker_image_size}MB)"
    echo "  Apple:   ${apple_build_time}s (${apple_image_size})"
}

# ─── Phase: Test ─────────────────────────────────────────────────────

do_test() {
    phase "Phase 3: Comparison Tests"

    # Source .env for workspace path
    if [ -f "$KIT_ROOT/.env" ]; then
        # shellcheck disable=SC1091
        source "$KIT_ROOT/.env"
    elif [ -f "$SCRIPT_DIR/.env" ]; then
        # shellcheck disable=SC1091
        source "$SCRIPT_DIR/.env"
    fi
    WORKSPACE=$(eval echo "${WORKSPACE:-/workspace}")

    # Create a temp directory for test artifacts
    local test_dir="$REPORT_DIR/test-artifacts"
    mkdir -p "$test_dir"

    # Write a small test file for I/O tests
    dd if=/dev/urandom of="$test_dir/testfile-64mb" bs=1m count=64 2>/dev/null
    ok "Test artifacts prepared"

    # ── Test 1: Container startup time ──
    info "Test 1: Container startup time (cold start)"

    # Docker startup
    info "  Docker: timing 'echo ready' in fresh container..."
    local docker_start_time
    docker_start_time=$({
        local s e
        s=$(python3 -c 'import time; print(f"{time.time():.3f}")')
        docker run --rm "$DOCKER_IMAGE" echo "ready" >/dev/null 2>&1
        e=$(python3 -c 'import time; print(f"{time.time():.3f}")')
        python3 -c "print(f'{$e - $s:.3f}')"
    })
    record "docker" "startup_cold" "$docker_start_time" "seconds"
    ok "  Docker cold start: ${docker_start_time}s"

    # Apple Containers startup
    info "  Apple: timing 'echo ready' in fresh container..."
    local apple_start_time
    apple_start_time=$({
        local s e
        s=$(python3 -c 'import time; print(f"{time.time():.3f}")')
        container run --rm "$APPLE_IMAGE" echo "ready" >/dev/null 2>&1
        e=$(python3 -c 'import time; print(f"{time.time():.3f}")')
        python3 -c "print(f'{$e - $s:.3f}')"
    })
    record "apple" "startup_cold" "$apple_start_time" "seconds"
    ok "  Apple cold start: ${apple_start_time}s"

    # ── Test 2: Tool availability smoke test ──
    info "Test 2: Tool availability inside container"

    local tools_to_check="git node python3 uv bun claude npm gh rustc tmux rg jq curl"

    info "  Docker: checking tools..."
    local docker_tools_ok=0 docker_tools_fail=0
    for tool in $tools_to_check; do
        if docker run --rm "$DOCKER_IMAGE" which "$tool" >/dev/null 2>&1; then
            docker_tools_ok=$((docker_tools_ok + 1))
        else
            warn "    Docker missing: $tool"
            docker_tools_fail=$((docker_tools_fail + 1))
        fi
    done
    record "docker" "tools_available" "$docker_tools_ok/$((docker_tools_ok + docker_tools_fail))"
    ok "  Docker: $docker_tools_ok/$((docker_tools_ok + docker_tools_fail)) tools available"

    info "  Apple: checking tools..."
    local apple_tools_ok=0 apple_tools_fail=0
    for tool in $tools_to_check; do
        if container run --rm "$APPLE_IMAGE" which "$tool" >/dev/null 2>&1; then
            apple_tools_ok=$((apple_tools_ok + 1))
        else
            warn "    Apple missing: $tool"
            apple_tools_fail=$((apple_tools_fail + 1))
        fi
    done
    record "apple" "tools_available" "$apple_tools_ok/$((apple_tools_ok + apple_tools_fail))"
    ok "  Apple: $apple_tools_ok/$((apple_tools_ok + apple_tools_fail)) tools available"

    # ── Test 3: Volume mount (bind mount) ──
    info "Test 3: Bind mount — write from host, read from container"

    echo "hello from host" > "$test_dir/mount-test.txt"

    info "  Docker: mounting $test_dir as /mnt/test..."
    local docker_mount_result
    docker_mount_result=$(docker run --rm -v "$test_dir:/mnt/test:ro" "$DOCKER_IMAGE" cat /mnt/test/mount-test.txt 2>&1)
    if [[ "$docker_mount_result" == "hello from host" ]]; then
        record "docker" "bind_mount" "pass"
        ok "  Docker bind mount: PASS"
    else
        record "docker" "bind_mount" "fail"
        err "  Docker bind mount: FAIL — got: $docker_mount_result"
    fi

    info "  Apple: mounting $test_dir..."
    local apple_mount_result
    # Apple Containers bind mount syntax may differ — try both --volume and --mount
    apple_mount_result=$(container run --rm --volume "$test_dir:/mnt/test:ro" "$APPLE_IMAGE" cat /mnt/test/mount-test.txt 2>&1) || \
    apple_mount_result=$(container run --rm --mount "type=bind,source=$test_dir,target=/mnt/test,readonly" "$APPLE_IMAGE" cat /mnt/test/mount-test.txt 2>&1) || \
    apple_mount_result="MOUNT_FAILED"
    if [[ "$apple_mount_result" == "hello from host" ]]; then
        record "apple" "bind_mount" "pass"
        ok "  Apple bind mount: PASS"
    else
        record "apple" "bind_mount" "fail: $apple_mount_result"
        err "  Apple bind mount: FAIL — got: $apple_mount_result"
    fi

    # ── Test 4: Write from container, read from host ──
    info "Test 4: Reverse bind mount — write from container, read from host"

    info "  Docker..."
    docker run --rm -v "$test_dir:/mnt/test" "$DOCKER_IMAGE" \
        sh -c 'echo "written by docker container" > /mnt/test/docker-wrote.txt' 2>&1
    if [[ -f "$test_dir/docker-wrote.txt" ]] && grep -q "written by docker" "$test_dir/docker-wrote.txt"; then
        record "docker" "reverse_bind_mount" "pass"
        ok "  Docker reverse mount: PASS"
    else
        record "docker" "reverse_bind_mount" "fail"
        err "  Docker reverse mount: FAIL"
    fi

    info "  Apple..."
    container run --rm --volume "$test_dir:/mnt/test" "$APPLE_IMAGE" \
        sh -c 'echo "written by apple container" > /mnt/test/apple-wrote.txt' 2>&1 || true
    if [[ -f "$test_dir/apple-wrote.txt" ]] && grep -q "written by apple" "$test_dir/apple-wrote.txt"; then
        record "apple" "reverse_bind_mount" "pass"
        ok "  Apple reverse mount: PASS"
    else
        record "apple" "reverse_bind_mount" "fail"
        err "  Apple reverse mount: FAIL"
    fi

    # ── Test 5: Port forwarding ──
    info "Test 5: Port forwarding — start HTTP server in container, curl from host"

    info "  Docker: starting Python HTTP server on port 18080..."
    docker run --rm -d --name experiment-docker-http \
        -p 18080:8000 "$DOCKER_IMAGE" \
        python3 -m http.server 8000 >/dev/null 2>&1
    sleep 2
    if curl -s --max-time 5 http://localhost:18080/ >/dev/null 2>&1; then
        record "docker" "port_forward" "pass"
        ok "  Docker port forward: PASS (localhost:18080 reachable)"
    else
        record "docker" "port_forward" "fail"
        err "  Docker port forward: FAIL"
    fi
    docker stop experiment-docker-http >/dev/null 2>&1 || true

    info "  Apple: starting Python HTTP server on port 18081..."
    container run --rm -d --name experiment-apple-http \
        --publish 18081:8000/tcp "$APPLE_IMAGE" \
        python3 -m http.server 8000 >/dev/null 2>&1 || \
    container run --rm -d --name experiment-apple-http \
        -p 18081:8000 "$APPLE_IMAGE" \
        python3 -m http.server 8000 >/dev/null 2>&1 || true
    sleep 3  # Apple Containers needs more startup time (VM boot)
    if curl -s --max-time 5 http://localhost:18081/ >/dev/null 2>&1; then
        record "apple" "port_forward" "pass"
        ok "  Apple port forward: PASS (localhost:18081 reachable)"
    else
        record "apple" "port_forward" "fail"
        err "  Apple port forward: FAIL"
    fi
    container stop experiment-apple-http >/dev/null 2>&1 || \
    container rm -f experiment-apple-http >/dev/null 2>&1 || true

    # ── Test 6: Multi-process (exec into running container) ──
    info "Test 6: Multi-process — run two processes in the same container"

    info "  Docker: starting container, then exec a second process..."
    docker run --rm -d --name experiment-docker-multi "$DOCKER_IMAGE" sleep 60 >/dev/null 2>&1
    sleep 1
    local docker_exec_result
    docker_exec_result=$(docker exec experiment-docker-multi sh -c 'echo "second process pid=$$"' 2>&1)
    if echo "$docker_exec_result" | grep -q "second process pid="; then
        record "docker" "multi_process_exec" "pass"
        ok "  Docker exec: PASS — $docker_exec_result"
    else
        record "docker" "multi_process_exec" "fail"
        err "  Docker exec: FAIL — $docker_exec_result"
    fi
    docker stop experiment-docker-multi >/dev/null 2>&1 || true

    info "  Apple: starting container, then exec a second process..."
    container run --rm -d --name experiment-apple-multi "$APPLE_IMAGE" sleep 60 >/dev/null 2>&1
    sleep 2
    local apple_exec_result
    apple_exec_result=$(container exec experiment-apple-multi sh -c 'echo "second process pid=$$"' 2>&1)
    if echo "$apple_exec_result" | grep -q "second process pid="; then
        record "apple" "multi_process_exec" "pass"
        ok "  Apple exec: PASS — $apple_exec_result"
    else
        record "apple" "multi_process_exec" "fail"
        err "  Apple exec: FAIL — $apple_exec_result"
    fi
    container stop experiment-apple-multi >/dev/null 2>&1 || \
    container rm -f experiment-apple-multi >/dev/null 2>&1 || true

    # ── Test 7: File I/O benchmark (sequential write inside container) ──
    info "Test 7: File I/O — sequential write 256MB inside container"

    info "  Docker..."
    local docker_io
    docker_io=$(docker run --rm "$DOCKER_IMAGE" sh -c '
        sync
        start=$(date +%s%N)
        dd if=/dev/zero of=/tmp/bench bs=1M count=256 conv=fdatasync 2>/dev/null
        end=$(date +%s%N)
        elapsed=$(( (end - start) / 1000000 ))
        speed=$(( 256 * 1000 / elapsed ))
        echo "${elapsed}ms ${speed}MB/s"
    ' 2>&1)
    record "docker" "seq_write_256mb" "$docker_io"
    ok "  Docker I/O: $docker_io"

    info "  Apple..."
    local apple_io
    apple_io=$(container run --rm "$APPLE_IMAGE" sh -c '
        sync
        start=$(date +%s%N)
        dd if=/dev/zero of=/tmp/bench bs=1M count=256 conv=fdatasync 2>/dev/null
        end=$(date +%s%N)
        elapsed=$(( (end - start) / 1000000 ))
        speed=$(( 256 * 1000 / elapsed ))
        echo "${elapsed}ms ${speed}MB/s"
    ' 2>&1)
    record "apple" "seq_write_256mb" "$apple_io"
    ok "  Apple I/O: $apple_io"

    # ── Test 8: File I/O on bind mount (host filesystem) ──
    info "Test 8: Bind mount I/O — sequential write 64MB on mounted volume"

    info "  Docker..."
    local docker_mount_io
    docker_mount_io=$(docker run --rm -v "$test_dir:/mnt/test" "$DOCKER_IMAGE" sh -c '
        sync
        start=$(date +%s%N)
        dd if=/dev/zero of=/mnt/test/bench-docker bs=1M count=64 conv=fdatasync 2>/dev/null
        end=$(date +%s%N)
        elapsed=$(( (end - start) / 1000000 ))
        speed=$(( 64 * 1000 / elapsed ))
        echo "${elapsed}ms ${speed}MB/s"
    ' 2>&1)
    record "docker" "mount_write_64mb" "$docker_mount_io"
    ok "  Docker mount I/O: $docker_mount_io"
    rm -f "$test_dir/bench-docker"

    info "  Apple..."
    local apple_mount_io
    apple_mount_io=$(container run --rm --volume "$test_dir:/mnt/test" "$APPLE_IMAGE" sh -c '
        sync
        start=$(date +%s%N)
        dd if=/dev/zero of=/mnt/test/bench-apple bs=1M count=64 conv=fdatasync 2>/dev/null
        end=$(date +%s%N)
        elapsed=$(( (end - start) / 1000000 ))
        speed=$(( 64 * 1000 / elapsed ))
        echo "${elapsed}ms ${speed}MB/s"
    ' 2>&1)
    record "apple" "mount_write_64mb" "$apple_mount_io"
    ok "  Apple mount I/O: $apple_mount_io"
    rm -f "$test_dir/bench-apple"

    # ── Test 9: CPU benchmark (sysbench-like — prime number calculation) ──
    info "Test 9: CPU benchmark — calculate primes to 20000"

    info "  Docker..."
    local docker_cpu
    docker_cpu=$(docker run --rm "$DOCKER_IMAGE" python3 -c '
import time
def is_prime(n):
    if n < 2: return False
    for i in range(2, int(n**0.5) + 1):
        if n % i == 0: return False
    return True
start = time.monotonic()
count = sum(1 for i in range(2, 20001) if is_prime(i))
elapsed = time.monotonic() - start
print(f"{elapsed:.3f}s ({count} primes)")
' 2>&1)
    record "docker" "cpu_primes_20k" "$docker_cpu"
    ok "  Docker CPU: $docker_cpu"

    info "  Apple..."
    local apple_cpu
    apple_cpu=$(container run --rm "$APPLE_IMAGE" python3 -c '
import time
def is_prime(n):
    if n < 2: return False
    for i in range(2, int(n**0.5) + 1):
        if n % i == 0: return False
    return True
start = time.monotonic()
count = sum(1 for i in range(2, 20001) if is_prime(i))
elapsed = time.monotonic() - start
print(f"{elapsed:.3f}s ({count} primes)")
' 2>&1)
    record "apple" "cpu_primes_20k" "$apple_cpu"
    ok "  Apple CPU: $apple_cpu"

    # ── Test 10: Memory overhead ──
    info "Test 10: Memory overhead — idle container memory usage"

    info "  Docker: starting idle container..."
    docker run --rm -d --name experiment-docker-mem "$DOCKER_IMAGE" sleep 120 >/dev/null 2>&1
    sleep 3
    local docker_mem
    docker_mem=$(docker stats --no-stream --format '{{.MemUsage}}' experiment-docker-mem 2>&1 || echo "unknown")
    record "docker" "idle_memory" "$docker_mem"
    ok "  Docker idle memory: $docker_mem"
    docker stop experiment-docker-mem >/dev/null 2>&1 || true

    info "  Apple: starting idle container..."
    container run --rm -d --name experiment-apple-mem "$APPLE_IMAGE" sleep 120 >/dev/null 2>&1
    sleep 4
    local apple_mem
    apple_mem=$(container stats experiment-apple-mem 2>&1 | tail -1 || echo "unknown")
    record "apple" "idle_memory" "$apple_mem"
    ok "  Apple idle memory: $apple_mem"
    container stop experiment-apple-mem >/dev/null 2>&1 || \
    container rm -f experiment-apple-mem >/dev/null 2>&1 || true

    # ── Test 11: Architecture check ──
    info "Test 11: Architecture reported inside container"

    local docker_arch apple_arch
    docker_arch=$(docker run --rm "$DOCKER_IMAGE" uname -m 2>&1)
    apple_arch=$(container run --rm "$APPLE_IMAGE" uname -m 2>&1)
    record "docker" "container_arch" "$docker_arch"
    record "apple" "container_arch" "$apple_arch"
    ok "  Docker reports: $docker_arch"
    ok "  Apple reports: $apple_arch"

    # ── Cleanup test artifacts ──
    rm -f "$test_dir/testfile-64mb" "$test_dir/mount-test.txt"
    rm -f "$test_dir/docker-wrote.txt" "$test_dir/apple-wrote.txt"

    echo ""
    ok "All tests complete. Results in $REPORT_DIR/results.csv"
}

# ─── Phase: Report ───────────────────────────────────────────────────

do_report() {
    phase "Phase 4: Comparison Report"

    if [[ ! -f "$REPORT_DIR/results.csv" ]]; then
        err "No results found. Run tests first: $0 test"
        exit 1
    fi

    # Generate markdown report
    cat > "$REPORT_FILE" << 'HEADER'
# Apple Containers vs OrbStack (Docker) — Experiment Report

HEADER

    echo "**Date:** $TIMESTAMP" >> "$REPORT_FILE"
    echo "**Machine:** $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown')" >> "$REPORT_FILE"
    echo "**macOS:** $(sw_vers -productVersion)" >> "$REPORT_FILE"
    echo "**Memory:** $(sysctl -n hw.memsize | awk '{printf "%.0f", $1/1073741824}')GB" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    echo "## Raw Results" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo '```' >> "$REPORT_FILE"
    echo "runtime,metric,value,unit" >> "$REPORT_FILE"
    cat "$REPORT_DIR/results.csv" >> "$REPORT_FILE"
    echo '```' >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    echo "## Summary Table" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "| Test | Docker (OrbStack) | Apple Containers | Notes |" >> "$REPORT_FILE"
    echo "|------|-------------------|------------------|-------|" >> "$REPORT_FILE"

    # Parse results.csv and build summary table
    while IFS=, read -r runtime metric value unit; do
        # Skip system metrics (already in header)
        [[ "$runtime" == "system" ]] && continue
        # Only show docker rows (we'll pair with apple)
        [[ "$runtime" != "docker" ]] && continue

        local apple_value
        apple_value=$(grep "^apple,$metric," "$REPORT_DIR/results.csv" | head -1 | cut -d, -f3)

        echo "| $metric | $value $unit | ${apple_value:-N/A} $unit | |" >> "$REPORT_FILE"
    done < "$REPORT_DIR/results.csv"

    echo "" >> "$REPORT_FILE"
    echo "## Build Logs" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "- Docker: \`$REPORT_DIR/docker-build.log\`" >> "$REPORT_FILE"
    echo "- Apple: \`$REPORT_DIR/apple-build.log\`" >> "$REPORT_FILE"

    ok "Report written to $REPORT_FILE"
    echo ""
    cat "$REPORT_FILE"
}

# ─── Phase: Teardown ────────────────────────────────────────────────

do_teardown() {
    phase "Teardown: Cleaning up experiment artifacts"

    info "Stopping any running experiment containers..."
    docker stop experiment-docker-http experiment-docker-multi experiment-docker-mem 2>/dev/null || true
    container stop experiment-apple-http experiment-apple-multi experiment-apple-mem 2>/dev/null || true
    container rm -f experiment-apple-http experiment-apple-multi experiment-apple-mem 2>/dev/null || true

    info "Removing Apple Containers image..."
    container image rm "$APPLE_IMAGE" 2>/dev/null || true

    # Don't remove the Docker image — it's the one they actually use
    info "Keeping Docker image ($DOCKER_IMAGE) — it's your working image."

    info "Cleaning test artifacts..."
    rm -rf "$REPORT_DIR/test-artifacts"

    ok "Teardown complete. Report preserved at $REPORT_DIR/"
    echo "  To fully clean up: rm -rf $REPORT_DIR"
}

# ─── Main ────────────────────────────────────────────────────────────

main() {
    local phase="${1:-all}"

    echo ""
    echo -e "${BOLD}Apple Containers vs OrbStack — Experiment Runner${NC}"
    echo -e "  Timestamp: $TIMESTAMP"
    echo -e "  Results:   $REPORT_DIR/"
    echo ""

    # Initialize results CSV (append mode — don't clobber if re-running single phase)
    if [[ "$phase" == "all" ]]; then
        echo "runtime,metric,value,unit" > "$REPORT_DIR/results.csv"
    fi

    case "$phase" in
        setup)    do_setup ;;
        build)    do_build ;;
        test)     do_test ;;
        report)   do_report ;;
        teardown) do_teardown ;;
        all)
            do_setup
            do_build
            do_test
            do_report
            echo ""
            phase "Experiment Complete"
            echo "  Report: $REPORT_FILE"
            echo "  Raw data: $REPORT_DIR/results.csv"
            echo "  Build logs: $REPORT_DIR/docker-build.log, $REPORT_DIR/apple-build.log"
            echo ""
            echo "  Next steps:"
            echo "    1. Review the report"
            echo "    2. Run ./apple-containers-experiment.sh teardown to clean up"
            echo "    3. If Apple Containers works well, we can adapt claude.sh to support it"
            ;;
        *)
            echo "Usage: $0 {setup|build|test|report|teardown|all}"
            exit 1
            ;;
    esac
}

main "$@"
