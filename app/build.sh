#!/usr/bin/env bash
set -euo pipefail

# Build script for Lambda function and layer
# Usage: ./build.sh
# PYTHON_VERSION environment variable is required (provided by tyhe justfile)

REPO_ROOT="$(git rev-parse --show-toplevel || exit 1)"
APP_DIR="${REPO_ROOT}/app"
DIST_DIR="${REPO_ROOT}/.dist"

echo "Building Lambda artifacts..."
echo "  Repository root: ${REPO_ROOT}"
echo "  Distribution directory: ${DIST_DIR}"
echo "  Python version: ${PYTHON_VERSION}"

mkdir -p "${DIST_DIR}/app" "${DIST_DIR}/layers/python"

echo "Copying Lambda function..."
cp "${APP_DIR}/lambda_function.py" "${DIST_DIR}/app/"

echo "Installing dependencies for Python ${PYTHON_VERSION}..."
cd "${APP_DIR}"
uv export --python "${PYTHON_VERSION}" --no-dev --format requirements-txt | uv pip install --python "${PYTHON_VERSION}" --only-binary=:all: -r - --target "${DIST_DIR}/layers/python"

echo "Creating lambda_function.zip..."
cd "${DIST_DIR}/app"
zip -q ../lambda_function.zip lambda_function.py

echo "Creating lambda_layer.zip..."
cd "${DIST_DIR}/layers"
zip -q -r ../lambda_layer.zip python/

echo "Build complete!"
echo "  Lambda function zip: ${DIST_DIR}/lambda_function.zip"
echo "  Lambda layer zip: ${DIST_DIR}/lambda_layer.zip"
