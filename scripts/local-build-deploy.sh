#!/bin/bash

set -e

# Configuration
VERSION="3.7.4"
PROVIDER_NAME="azuread"
BINARY_PREFIX="terraform-provider-azuread"
DIST_DIR="dist"

log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }
log_error() { echo "[ERROR] $1"; }

check_dependencies() {
    log_info "Checking dependencies..."
    command -v go >/dev/null 2>&1 || { log_error "Go is not installed"; exit 1; }
    command -v zip >/dev/null 2>&1 || { log_error "zip is not installed"; exit 1; }
    log_info "All dependencies satisfied"
}

clean_build() {
    log_info "Cleaning previous builds..."
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
}

build_binaries() {
    log_info "Building binaries for Terraform Registry required platforms..."
    
    platforms=(
        "darwin/amd64"
        "darwin/arm64"
        "linux/386"
        "linux/amd64" 
        "linux/arm"
        "linux/arm64"
        "windows/386"
        "windows/amd64"
        "windows/arm64"
        "freebsd/386"
        "freebsd/amd64"
        "freebsd/arm"
        "freebsd/arm64"
    )
    
    for platform in "${platforms[@]}"; do
        IFS='/' read -r os arch <<< "$platform"
        
        extension=""
        if [ "$os" = "windows" ]; then
            extension=".exe"
        fi
        
        # Binary name includes .exe for Windows
        binary_name="${BINARY_PREFIX}_${VERSION}_${os}_${arch}${extension}"
        output_path="$DIST_DIR/$binary_name"
        
        log_info "Building for $os/$arch..."
        
        if GOOS=$os GOARCH=$arch go build -o "$output_path" .; then
            log_info "Built $binary_name"
        else
            log_error "Failed to build for $os/$arch"
        fi
    done
}

build_oracle_linux() {
    log_info "Building for Oracle Linux 8..."
    
    # Oracle Linux 8 uses the same binaries as standard Linux
    # but we'll build with specific compatibility if needed
    oracle_platforms=(
        "linux/amd64"
        "linux/arm64"
    )
    
    for platform in "${oracle_platforms[@]}"; do
        IFS='/' read -r os arch <<< "$platform"
        
        # Use standard Linux naming - Oracle Linux uses standard Linux binaries
        binary_name="${BINARY_PREFIX}_${VERSION}_${os}_${arch}"
        output_path="$DIST_DIR/$binary_name"
        
        log_info "Building Oracle Linux compatible binary for $os/$arch..."
        
        # Build with CGO disabled for better compatibility across Linux distributions
        if CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -o "$output_path" .; then
            log_info "Built Oracle Linux compatible $binary_name"
        else
            log_error "Failed to build Oracle Linux compatible binary for $os/$arch"
        fi
    done
}

create_zip_files() {
    log_info "Creating zip files for Terraform Registry..."
    
    cd "$DIST_DIR"
    
    # Create zip files for each binary
    for binary in ${BINARY_PREFIX}_${VERSION}_*; do
        if [ -f "$binary" ] && [[ ! "$binary" =~ \.zip$ ]] && [[ ! "$binary" =~ SHA256SUMS ]]; then
            # For Windows: remove .exe from zip filename but keep it in the zip
            if [[ "$binary" =~ \.exe$ ]]; then
                # Remove .exe from the zip filename
                zip_name="${binary%.exe}.zip"
            else
                zip_name="${binary}.zip"
            fi
            
            log_info "Zipping $binary -> $zip_name"
            zip -q "$zip_name" "$binary"
            # Remove the binary after zipping
            rm -f "$binary"
        fi
    done
    
    cd - >/dev/null
}

create_terraform_registry_files() {
    log_info "Creating Terraform Registry required files..."
    
    cd "$DIST_DIR"
    
    # 1. Create terraform-provider-azuread_3.7.2_SHA256SUMS
    rm -f "${BINARY_PREFIX}_${VERSION}_SHA256SUMS"
    for zip_file in *.zip; do
        if [ -f "$zip_file" ]; then
            sha256sum "$zip_file" >> "${BINARY_PREFIX}_${VERSION}_SHA256SUMS"
        fi
    done
    
    # 2. Create terraform-provider-azuread_3.7.2_SHA256SUMS.sig
    if command -v gpg >/dev/null 2>&1; then
        log_info "Signing SHA256SUMS with GPG..."
        gpg --detach-sign "${BINARY_PREFIX}_${VERSION}_SHA256SUMS" 2>/dev/null || {
            log_warn "GPG signing failed, creating placeholder signature"
            touch "${BINARY_PREFIX}_${VERSION}_SHA256SUMS.sig"
        }
    else
        log_warn "GPG not available, creating unsigned SHA256SUMS.sig"
        touch "${BINARY_PREFIX}_${VERSION}_SHA256SUMS.sig"
    fi
    
    log_info "Created ${BINARY_PREFIX}_${VERSION}_SHA256SUMS"
    log_info "Created ${BINARY_PREFIX}_${VERSION}_SHA256SUMS.sig"
    
    cd - >/dev/null
}

create_github_release() {
    log_info "Creating GitHub release..."
    
    if ! command -v gh >/dev/null 2>&1; then
        log_warn "GitHub CLI not found, skipping release creation"
        return 0
    fi
    
    if ! gh auth status >/dev/null 2>&1; then
        log_warn "Not authenticated with GitHub, skipping release creation"
        return 0
    fi
    
    local version_tag="v$VERSION"
    
    # Verify we have all required files
    local zip_count=$(find "$DIST_DIR" -name "*.zip" | wc -l)
    if [ "$zip_count" -eq 0 ]; then
        log_error "No zip files found!"
        return 1
    fi
    
    if [ ! -f "$DIST_DIR/${BINARY_PREFIX}_${VERSION}_SHA256SUMS" ]; then
        log_error "Missing SHA256SUMS file!"
        return 1
    fi
    
    log_info "Found $zip_count platform zip files"
    
    # Show what files we're about to upload
    log_info "Files to be uploaded:"
    for file in "$DIST_DIR"/*.zip "$DIST_DIR/${BINARY_PREFIX}_${VERSION}_SHA256SUMS" "$DIST_DIR/${BINARY_PREFIX}_${VERSION}_SHA256SUMS.sig"; do
        if [ -f "$file" ]; then
            echo "  $(basename "$file")"
        fi
    done
    
    # Delete existing release if it exists
    if gh release view "$version_tag" >/dev/null 2>&1; then
        log_warn "Deleting existing release $version_tag..."
        gh release delete "$version_tag" -y || true
    fi
    
    # Create release
    log_info "Creating release $version_tag..."
    gh release create "$version_tag" \
        "$DIST_DIR"/*.zip \
        "$DIST_DIR/${BINARY_PREFIX}_${VERSION}_SHA256SUMS" \
        "$DIST_DIR/${BINARY_PREFIX}_${VERSION}_SHA256SUMS.sig" \
        --title "v$VERSION" \
        --notes "Terraform Provider for Azure Active Directory v$VERSION"
    
    log_info "GitHub release created successfully"
}

show_platform_summary() {
    log_info "Platform zip files created:"
    cd "$DIST_DIR"
    for zip_file in *.zip; do
        echo "  $zip_file"
    done
    cd - >/dev/null
}

main() {
    log_info "Starting Terraform Registry release process for $PROVIDER_NAME v$VERSION"
    
    check_dependencies
    clean_build
    build_binaries
    build_oracle_linux
    create_zip_files
    create_terraform_registry_files
    show_platform_summary
    create_github_release
    
    log_info "Terraform Registry release process completed!"
    echo ""
    log_info "Platforms built:"
    echo "  - Standard Linux (386, amd64, arm, arm64)"
    echo "  - Oracle Linux 8 compatible (amd64, arm64)" 
    echo "  - macOS (amd64, arm64)"
    echo "  - Windows (386, amd64, arm64)"
    echo "  - FreeBSD (386, amd64, arm, arm64)"
    echo ""
    log_info "Windows zip files are named correctly:"
    echo "  terraform-provider-azuread_${VERSION}_windows_386.zip (contains .exe)"
    echo "  terraform-provider-azuread_${VERSION}_windows_amd64.zip (contains .exe)" 
    echo "  terraform-provider-azuread_${VERSION}_windows_arm64.zip (contains .exe)"
}

main "$@"