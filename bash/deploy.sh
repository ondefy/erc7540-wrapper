#!/bin/bash
# =============================================================================
# Deploy All - Deploys implementation, beacon, and wrapper in one tx via CREATE3
# Deterministic addresses across all EVMs with same salt
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
    echo "Copy .env.example to .env and fill in your values"
    exit 1
fi

# Validate required variables
REQUIRED_VARS="PRIVATE_KEY DEPLOY_SALT OWNER OPERATOR SMART_ACCOUNT UNDERLYING_TOKEN VAULT_NAME VAULT_SYMBOL"
for var in $REQUIRED_VARS; do
    if [ -z "${!var}" ]; then
        echo "Error: $var not set in .env"
        exit 1
    fi
done

NETWORK=${NETWORK:-base}

# Get predicted addresses first
echo "=========================================="
echo "CREATE3 Deployment Preview"
echo "=========================================="
echo "Network:          $NETWORK"
echo "Salt:             $DEPLOY_SALT"
echo ""
echo "Parameters:"
echo "  Owner:            $OWNER"
echo "  Operator:         $OPERATOR"
echo "  Smart Account:    $SMART_ACCOUNT"
echo "  Underlying Token: $UNDERLYING_TOKEN"
echo "  Vault Name:       $VAULT_NAME"
echo "  Vault Symbol:     $VAULT_SYMBOL"
echo "=========================================="
echo ""

# Run prediction script
echo "Predicting addresses..."
cd "$PROJECT_ROOT"
set +e
forge script script/Deploy.s.sol:PredictAddresses --rpc-url "$NETWORK" 2>&1 | tee /tmp/predict_output.txt
PREDICT_EXIT=${PIPESTATUS[0]}
set -e

if [ $PREDICT_EXIT -ne 0 ]; then
    echo ""
    echo "Prediction FAILED. Check output above."
    exit 1
fi

grep -E "(Predicted|Implementation|Beacon|Wrapper|Salt):" /tmp/predict_output.txt || true

echo ""
echo "=========================================="
echo ""

# Prompt for confirmation
read -p "Deploy with these addresses? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled"
    exit 0
fi

echo ""
echo "Deploying..."
set +e
forge script script/Deploy.s.sol:DeployAll \
    --rpc-url "$NETWORK" \
    --broadcast \
    --private-key "$PRIVATE_KEY" \
    -vvvv 2>&1 | tee /tmp/deploy_output.txt
EXIT_CODE=${PIPESTATUS[0]}
set -e

RESULT=$(cat /tmp/deploy_output.txt)

if [ $EXIT_CODE -ne 0 ]; then
    echo ""
    echo "=========================================="
    echo "Deployment FAILED (exit code: $EXIT_CODE)"
    echo "=========================================="
    exit 1
fi

# Extract addresses from output
IMPL_ADDR=$(echo "$RESULT" | grep -oE "Implementation: (0x[a-fA-F0-9]{40})" | tail -1 | cut -d' ' -f2)
BEACON_ADDR=$(echo "$RESULT" | grep -oE "Beacon: (0x[a-fA-F0-9]{40})" | tail -1 | cut -d' ' -f2)
WRAPPER_ADDR=$(echo "$RESULT" | grep -oE "Wrapper: (0x[a-fA-F0-9]{40})" | tail -1 | cut -d' ' -f2)

if [ -n "$IMPL_ADDR" ] && [ -n "$BEACON_ADDR" ] && [ -n "$WRAPPER_ADDR" ]; then
    echo ""
    echo "=========================================="
    echo "Deployment successful!"
    echo "=========================================="
    echo "Implementation: $IMPL_ADDR"
    echo "Beacon:         $BEACON_ADDR"
    echo "Wrapper:        $WRAPPER_ADDR"
    echo ""
    echo "Add to .env:"
    echo "  BEACON_ADDRESS=$BEACON_ADDR"
    echo "  WRAPPER_ADDRESS=$WRAPPER_ADDR"
    echo ""
    echo "Verify contracts:"
    echo "  ./bash/verify.sh implementation $IMPL_ADDR"
    echo "  ./bash/verify.sh beacon $BEACON_ADDR"
    echo "  ./bash/verify.sh wrapper $WRAPPER_ADDR"
    echo "=========================================="
else
    echo ""
    echo "Deployment completed. Check output above for addresses."
fi
