#!/usr/bin/env bash

# Check if .env file exists
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
    echo "Variables loaded from .env"
else
    echo "Error: .env file not found!"
    exit 1
fi

# Run the mirror script
bash scripts/mirror-to-ghcr.sh