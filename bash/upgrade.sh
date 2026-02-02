#!/bin/bash
# =============================================================================
# Upgrade Beacon - Deploys new implementation and upgrades all wrappers
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load environment variables
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
elif [ -f "$PROJECT_ROOT/.env" ]; then
    source "$PROJECT_ROOT/.env"
else
    echo "Error: .env file not found"
    exit 1
fi

# Validate required variables
REQUIRED_VARS="PRIVATE_KEY BEACON_ADDRESS WRAPPER_ADDRESS OWNER"
for var in $REQUIRED_VARS; do
    if [ -z "${!var}" ]; then
        echo "Error: $var not set in .env"
        exit 1
    fi
done

NETWORK=${NETWORK:-base}

echo "=========================================="
echo "Upgrading Beacon Implementation"
echo "=========================================="
echo "Network: $NETWORK"
echo "Beacon:  $BEACON_ADDRESS"
echo "Wrapper: $WRAPPER_ADDRESS"
echo "Owner:   $OWNER"
echo "=========================================="
echo ""

# Show what will change
echo "This will:"
echo "  1. Deploy new SmartAccountWrapper implementation"
echo "  2. Upgrade beacon to point to new implementation"
echo "  3. Reinitialize wrapper with owner"
echo "  4. ALL proxies using this beacon will be upgraded"
echo ""

# Prompt for confirmation
read -p "Continue with upgrade? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Upgrade cancelled"
    exit 0
fi

cd "$PROJECT_ROOT"

echo ""
echo "Deploying new implementation and upgrading beacon..."
set +e
forge script script/Upgrade.s.sol:Upgrade \
    --rpc-url "$NETWORK" \
    --broadcast \
    --private-key "$PRIVATE_KEY" \
    -vvvv 2>&1 | tee /tmp/upgrade_output.txt
EXIT_CODE=${PIPESTATUS[0]}
set -e

RESULT=$(cat /tmp/upgrade_output.txt)

if [ $EXIT_CODE -ne 0 ]; then
    echo ""
    echo "=========================================="
    echo "Upgrade FAILED (exit code: $EXIT_CODE)"
    echo "=========================================="
    exit 1
fi

# Extract new implementation address
NEW_IMPL=$(echo "$RESULT" | grep -oE "new SmartAccountWrapper@(0x[a-fA-F0-9]{40})" | head -1 | cut -d'@' -f2)

if [ -n "$NEW_IMPL" ]; then
    echo ""
    echo "=========================================="
    echo "Upgrade successful!"
    echo "=========================================="
    echo "New Implementation: $NEW_IMPL"
    echo ""
    echo "All proxies using beacon $BEACON_ADDRESS"
    echo "are now using the new implementation."
    echo ""
    echo "Verify:"
    echo "  ./bash/verify.sh implementation $NEW_IMPL"
    echo "=========================================="
else
    echo ""
    echo "Upgrade completed. Check output above for details."
fi
