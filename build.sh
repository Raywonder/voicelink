#!/bin/bash

# VoiceLink Local Build Script
# Builds the application from the source directory

set -e

echo "🚀 VoiceLink Local Build Script"
echo "==============================="

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check if we're in the right directory
if [ ! -d "source" ]; then
    echo -e "${RED}Error: source directory not found. Please run this script from the project root.${NC}"
    exit 1
fi

# Change to source directory
cd source

echo -e "${BLUE}📁 Working directory: $(pwd)${NC}"

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install to /Applications
install_to_applications() {
    local app_name="VoiceLink Local.app"
    local releases_dir="../releases"
    local app_path=""

    # Find the built app
    if [ -d "${releases_dir}/mac/${app_name}" ]; then
        app_path="${releases_dir}/mac/${app_name}"
    elif [ -d "${releases_dir}/mac-arm64/${app_name}" ]; then
        app_path="${releases_dir}/mac-arm64/${app_name}"
    else
        echo -e "${RED}Error: Built app not found in releases directory${NC}"
        return 1
    fi

    # Remove existing app if it exists
    if [ -d "/Applications/${app_name}" ]; then
        echo -e "${YELLOW}Removing existing app from /Applications...${NC}"
        rm -rf "/Applications/${app_name}"
    fi

    # Copy new app to /Applications
    echo -e "${BLUE}Copying ${app_name} to /Applications...${NC}"
    cp -R "${app_path}" "/Applications/"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Successfully installed to /Applications${NC}"
    else
        echo -e "${RED}❌ Failed to install to /Applications${NC}"
        return 1
    fi
}

# Check dependencies
echo -e "${YELLOW}🔍 Checking dependencies...${NC}"

if ! command_exists node; then
    echo -e "${RED}Error: Node.js is required but not installed.${NC}"
    exit 1
fi

if ! command_exists npm; then
    echo -e "${RED}Error: npm is required but not installed.${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Node.js and npm are installed${NC}"

# Install dependencies if needed
if [ ! -d "node_modules" ]; then
    echo -e "${YELLOW}📦 Installing dependencies...${NC}"
    npm install
    echo -e "${GREEN}✅ Dependencies installed${NC}"
fi

# Build tasks
case "${1:-dev}" in
    "dev")
        echo -e "${BLUE}🔨 Building for development...${NC}"
        npm run build:dev
        echo -e "${GREEN}✅ Development build completed${NC}"
        ;;
    "prod")
        echo -e "${BLUE}🔨 Building for production...${NC}"
        npm run build:prod
        echo -e "${GREEN}✅ Production build completed${NC}"
        ;;
    "package")
        echo -e "${BLUE}📦 Packaging application...${NC}"
        npm run package
        echo -e "${GREEN}✅ Application packaged${NC}"
        ;;
    "mac")
        echo -e "${BLUE}🍎 Building for macOS...${NC}"
        npm run build:mac
        echo -e "${GREEN}✅ macOS build completed${NC}"

        # Install to Applications
        if [ "$2" = "install" ]; then
            echo -e "${YELLOW}📱 Installing to /Applications...${NC}"
            install_to_applications
        fi
        ;;
    "win")
        echo -e "${BLUE}🪟 Building for Windows...${NC}"
        npm run build:win
        echo -e "${GREEN}✅ Windows build completed${NC}"
        ;;
    "linux")
        echo -e "${BLUE}🐧 Building for Linux...${NC}"
        npm run build:linux
        echo -e "${GREEN}✅ Linux build completed${NC}"
        ;;
    "all")
        echo -e "${BLUE}🌍 Building for all platforms...${NC}"
        npm run build:all
        echo -e "${GREEN}✅ All platform builds completed${NC}"

        # Install to Applications on macOS if requested
        if [ "$2" = "install" ]; then
            echo -e "${YELLOW}📱 Installing to /Applications...${NC}"
            install_to_applications
        fi
        ;;
    "clean")
        echo -e "${YELLOW}🧹 Cleaning build artifacts...${NC}"
        npm run clean
        rm -rf ../build-temp/*
        rm -rf ../releases/*
        echo -e "${GREEN}✅ Build artifacts cleaned${NC}"
        ;;
    "test")
        echo -e "${BLUE}🧪 Running tests...${NC}"
        npm test
        echo -e "${GREEN}✅ Tests completed${NC}"
        ;;
    *)
        echo -e "${YELLOW}Usage: $0 [dev|prod|package|mac|win|linux|all|clean|test] [install]${NC}"
        echo ""
        echo "Commands:"
        echo "  dev      - Build for development"
        echo "  prod     - Build for production"
        echo "  package  - Package the application"
        echo "  mac      - Build for macOS (add 'install' to install to /Applications)"
        echo "  win      - Build for Windows"
        echo "  linux    - Build for Linux"
        echo "  all      - Build for all platforms (add 'install' to install Mac app)"
        echo "  clean    - Clean build artifacts"
        echo "  test     - Run tests"
        echo ""
        echo "Examples:"
        echo "  $0 mac install    - Build for macOS and install to /Applications"
        echo "  $0 all install    - Build for all platforms and install Mac app"
        ;;
esac

echo ""
echo -e "${GREEN}🎉 Build script completed!${NC}"

# Return to original directory
cd ..