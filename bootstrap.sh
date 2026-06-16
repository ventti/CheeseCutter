#!/usr/bin/env bash
#
# CheeseCutter Bootstrap Script
# Sets up the development environment on macOS or Linux and does a test build.
# For Windows, run bootstrap-windows.sh from a Git Bash shell.
# See doc/BUILD.md for the full cross-platform guide.
#

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }

# Build acme from source when the platform has no package for it.
build_acme_from_source() {
    local prefix="${1:-/usr/local/bin}"
    log_info "Building acme from source (github.com/meonwax/acme)..."
    local tmp
    tmp=$(mktemp -d)
    git clone --depth 1 https://github.com/meonwax/acme "$tmp/acme"
    make -C "$tmp/acme/src"
    sudo cp "$tmp/acme/src/acme" "$prefix/"
    log_success "acme installed to $prefix"
}

# --------------------------------------------------------------------------------
# macOS setup
# --------------------------------------------------------------------------------
setup_macos() {
    # Homebrew
    log_info "Checking for Homebrew..."
    if ! command -v brew &> /dev/null; then
        log_warning "Homebrew not found. Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        if [[ $(uname -m) == 'arm64' ]]; then
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
            eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
        log_success "Homebrew installed"
    else
        log_success "Homebrew found"
    fi

    # Xcode Command Line Tools (make, clang)
    log_info "Checking for Xcode Command Line Tools..."
    if ! xcode-select -p &> /dev/null; then
        log_warning "Xcode Command Line Tools not found. Installing..."
        xcode-select --install
        log_info "Complete the Xcode CLT installation, then re-run this script."
        exit 1
    fi
    log_success "Xcode Command Line Tools found"

    log_info "Installing system dependencies (ldc, acme, sdl2)..."
    brew install ldc acme sdl2 2>/dev/null || \
        log_warning "Some packages may already be installed, continuing..."
    log_success "System dependencies installed"

    if [[ $(uname -m) == 'arm64' ]]; then
        LIBSPATH="/opt/homebrew/lib"
    else
        LIBSPATH="/usr/local/lib"
    fi
    export LIBSPATH
    MAKE_ARGS=(-f Makefile.mac LIBSPATH="$LIBSPATH")
    log_success "Using LIBSPATH=$LIBSPATH"
}

# --------------------------------------------------------------------------------
# Linux setup
# --------------------------------------------------------------------------------
setup_linux() {
    log_info "Installing system dependencies..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update
        sudo apt-get install -y ldc acme libsdl2-dev libcurl4-openssl-dev g++ make git
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y ldc SDL2-devel libcurl-devel gcc-c++ make git
        command -v acme &> /dev/null || build_acme_from_source /usr/local/bin
    elif command -v pacman &> /dev/null; then
        sudo pacman -S --needed --noconfirm ldc sdl2 curl gcc make git
        command -v acme &> /dev/null || {
            log_warning "acme not found -- install from the AUR (e.g. 'yay -S acme') or build from source."
            build_acme_from_source /usr/local/bin
        }
    else
        log_error "Unsupported distro. Install manually: ldc acme libsdl2-dev libcurl-dev g++ make git"
        log_info "acme source: https://github.com/meonwax/acme (make -C src)"
        exit 1
    fi
    log_success "System dependencies installed"
    MAKE_ARGS=()  # the default Makefile is the Linux one
}

# --------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------
echo ""
echo "======================================"
echo "  CheeseCutter Development Setup"
echo "======================================"
echo ""

case "$OSTYPE" in
    darwin*) PLATFORM="macOS";  setup_macos ;;
    linux*)  PLATFORM="Linux";  setup_linux ;;
    msys*|cygwin*)
        log_error "Windows detected. Run ./bootstrap-windows.sh from a Git Bash shell."
        exit 1 ;;
    *)
        log_error "Unsupported platform: $OSTYPE"
        exit 1 ;;
esac

# mise (optional task runner; build also works with plain make)
log_info "Checking for mise..."
if ! command -v mise &> /dev/null; then
    log_warning "mise not found. Installing mise..."
    curl https://mise.run | sh
    SHELL_NAME=$(basename "$SHELL")
    case "$SHELL_NAME" in
        bash) echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc ;;
        zsh)  echo 'eval "$(~/.local/bin/mise activate zsh)"'  >> ~/.zshrc ;;
        fish) echo '~/.local/bin/mise activate fish | source'  >> ~/.config/fish/config.fish ;;
        *)    log_warning "Unknown shell: $SHELL_NAME. Add mise activation manually." ;;
    esac
    export PATH="$HOME/.local/bin:$PATH"
    log_success "mise installed"
else
    log_success "mise found"
fi
command -v mise &> /dev/null && mise trust 2>/dev/null || true

# Verify toolchain
echo ""
log_info "Verifying installations..."
command -v ldc2 &> /dev/null && log_success "ldc: $(ldc2 --version | head -n1)" || { log_error "ldc2 not found"; exit 1; }
command -v acme &> /dev/null && log_success "acme: $(command -v acme)"          || { log_error "acme not found"; exit 1; }

# Test build
echo ""
log_info "Building C64 player binary..."
make "${MAKE_ARGS[@]}" src/c64/player.bin && log_success "player.bin built" \
    || log_warning "Failed to build player.bin (try again after fixing acme)"

echo ""
log_info "Attempting test build..."
if make "${MAKE_ARGS[@]}" ccutter; then
    log_success "CheeseCutter built successfully!"
else
    log_error "Build failed. Please check the errors above."
    exit 1
fi

echo ""
echo "======================================"
log_success "Setup complete! ($PLATFORM)"
echo "======================================"
echo ""
echo "Common commands:"
echo "  ${GREEN}mise run build${NC}        - Build CheeseCutter"
echo "  ${GREEN}mise run run${NC}          - Build and run"
echo "  ${GREEN}mise run build-utils${NC}  - Build ct2util utility"
echo "  ${GREEN}mise run clean${NC}        - Clean build artifacts"
echo ""
if [[ "$PLATFORM" == "macOS" ]]; then
    echo "Or with make directly:  ${GREEN}make ${MAKE_ARGS[*]}${NC}"
else
    echo "Or with make directly:  ${GREEN}make${NC}"
fi
echo ""
echo "See doc/BUILD.md for the full guide."
echo ""
