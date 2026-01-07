#!/bin/bash

# Configuration
LAYER_NAME=$1
NODE_RUNTIME="nodejs24.x"

# Function to prompt for input if not provided
get_input() {
    local prompt_text=$1
    local var_value=$2
    if [ -z "$var_value" ]; then
        read -p "$prompt_text: " input
        echo "$input"
    else
        echo "$var_value"
    fi
}

# 1. Get Layer Name
LAYER_NAME=$(get_input "Enter desired Layer Name (e.g., pdf-lib-layer)" "$LAYER_NAME")

echo "--- Building Lambda Layer: $LAYER_NAME ---"

# 2. Prepare Directory Structure
echo "Cleaning up old build artifacts..."
rm -rf nodejs pdf_lib_layer.zip
mkdir nodejs

# 3. Install dependencies
echo "Installing dependencies..."
# Copy package.json to nodejs/ so npm installs there
cp package.json nodejs/
npm install --prefix nodejs --omit=dev --quiet

# 4. Zip the layer
echo "Zipping layer..."
zip -r pdf_lib_layer.zip nodejs > /dev/null

# 5. Publish Layer to AWS
echo "Publishing layer to AWS..."
LAYER_VERSION_ARN=$(aws lambda publish-layer-version \
    --layer-name "$LAYER_NAME" \
    --zip-file fileb://pdf_lib_layer.zip \
    --compatible-runtimes $NODE_RUNTIME \
    --output text \
    --query 'LayerVersionArn')

if [ $? -eq 0 ]; then
    echo "Success. Layer ARN: $LAYER_VERSION_ARN"
    # Save ARN to a temp file for the next script to pick up automatically
    echo "$LAYER_VERSION_ARN" > .last_layer_arn
else
    echo "Failed to publish layer."
    exit 1
fi

# Cleanup
rm -rf nodejs pdf_lib_layer.zip
