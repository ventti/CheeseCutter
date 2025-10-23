#!/usr/bin/env bash
#
# CheeseCutter Bootstrap Script
# This script sets up the development environment for CheeseCutter
#

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

# Check if running on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    log_error "This bootstrap script is currently designed for macOS only."
    log_info "For Linux, please ensure you have: gdc/ldc, acme, SDL development libraries, and make installed."
    exit 1
fi

echo ""
echo "======================================"
echo "  CheeseCutter Development Setup"
echo "======================================"
echo ""

# Step 1: Check and install Homebrew
log_info "Checking for Homebrew..."
if ! command -v brew &> /dev/null; then
    log_warning "Homebrew not found. Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    
    # Add Homebrew to PATH for Apple Silicon Macs
    if [[ $(uname -m) == 'arm64' ]]; then
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    
    log_success "Homebrew installed"
else
    log_success "Homebrew found"
fi

# Step 2: Check and install mise
log_info "Checking for mise..."
if ! command -v mise &> /dev/null; then
    log_warning "mise not found. Installing mise..."
    curl https://mise.run | sh
    
    # Add mise to shell configuration
    SHELL_NAME=$(basename "$SHELL")
    case "$SHELL_NAME" in
        bash)
            echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc
            export PATH="$HOME/.local/bin:$PATH"
            eval "$(~/.local/bin/mise activate bash)"
            ;;
        zsh)
            echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc
            export PATH="$HOME/.local/bin:$PATH"
            eval "$(~/.local/bin/mise activate zsh)"
            ;;
        fish)
            echo '~/.local/bin/mise activate fish | source' >> ~/.config/fish/config.fish
            ;;
        *)
            log_warning "Unknown shell: $SHELL_NAME. Please add mise activation manually."
            export PATH="$HOME/.local/bin:$PATH"
            ;;
    esac
    
    log_success "mise installed"
else
    log_success "mise found"
fi

# Ensure mise is in PATH for this script
if ! command -v mise &> /dev/null; then
    export PATH="$HOME/.local/bin:$PATH"
fi

# Step 3: Install system dependencies via Homebrew
log_info "Installing system dependencies (ldc, acme, SDL 1.2)..."
brew install ldc acme sdl 2>/dev/null || {
    log_warning "Some packages may already be installed, continuing..."
}
log_success "System dependencies installed"

# Step 4: Verify mise.toml exists
log_info "Checking mise configuration..."
if [ -f "mise.toml" ]; then
    log_success "mise.toml found (used for environment variables and tasks)"
else
    log_warning "mise.toml not found"
fi

# Step 5: Verify Xcode Command Line Tools
log_info "Checking for Xcode Command Line Tools..."
if ! xcode-select -p &> /dev/null; then
    log_warning "Xcode Command Line Tools not found. Installing..."
    xcode-select --install
    log_info "Please complete the Xcode Command Line Tools installation and run this script again."
    exit 1
else
    log_success "Xcode Command Line Tools found"
fi

# Step 6: Verify installations
echo ""
log_info "Verifying installations..."

# Check ldc
if command -v ldc2 &> /dev/null; then
    LDC_VERSION=$(ldc2 --version | head -n 1)
    log_success "ldc: $LDC_VERSION"
else
    log_error "ldc2 not found"
    exit 1
fi

# Check acme
if command -v acme &> /dev/null; then
    log_success "acme: $(which acme)"
else
    log_error "acme not found"
    exit 1
fi

# Check SDL
if brew list sdl &> /dev/null; then
    log_success "SDL 1.2: installed via Homebrew"
else
    log_warning "SDL 1.2 may not be properly installed"
fi

# Step 7: Set up environment variables
echo ""
log_info "Setting up environment variables..."

# Detect library path
if [[ $(uname -m) == 'arm64' ]]; then
    LIBSPATH="/opt/homebrew/lib"
else
    LIBSPATH="/usr/local/lib"
fi

log_success "Using LIBSPATH=$LIBSPATH"

# Step 8: Build the C64 player binary
echo ""
log_info "Building C64 player binary..."
if make -f Makefile.mac LIBSPATH="$LIBSPATH" src/c64/player.bin; then
    log_success "C64 player binary built"
else
    log_warning "Failed to build C64 player binary (you can try building manually later)"
fi

# Step 9: Test build
echo ""
log_info "Attempting test build..."
if make -f Makefile.mac LIBSPATH="$LIBSPATH" ccutter; then
    log_success "CheeseCutter built successfully!"
else
    log_error "Build failed. Please check the errors above."
    exit 1
fi

# Final instructions
echo ""
echo "======================================"
log_success "Setup complete!"
echo "======================================"
echo ""
echo "You can now use the following commands:"
echo ""
echo "  ${GREEN}mise run build${NC}        - Build CheeseCutter"
echo "  ${GREEN}mise run build-utils${NC}  - Build ct2util utility"
echo "  ${GREEN}mise run clean${NC}        - Clean build artifacts"
echo ""
echo "Or use make directly:"
echo "  ${GREEN}make -f Makefile.mac LIBSPATH=$LIBSPATH${NC}"
echo ""
echo "All dependencies are installed via Homebrew and are in your PATH."
echo "mise is configured for environment variables and convenient build tasks."
echo ""

