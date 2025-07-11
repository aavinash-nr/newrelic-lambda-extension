#!/usr/bin/env bash

set -Eeuo pipefail

# https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html
#  Python 3.13 | Amazon Linux 2023
#  Python 3.12 | Amazon Linux 2023
#  Python 3.11 | Amazon Linux 2
#  Node.js 22.x | Amazon Linux 2023
#  Node.js 20.x | Amazon Linux 2023  
#  Node.js 18.x | Amazon Linux 2

BUILD_DIR=python
NODEJS_BUILD_DIR=nodejs
DIST_DIR=dist

BUCKET_PREFIX=nr-extension-test-layers

EXTENSION_DIST_ZIP_ARM64=$DIST_DIR/extension.arm64.zip
EXTENSION_DIST_ZIP_X86_64=$DIST_DIR/extension.x86_64.zip

PY311_DIST_ARM64=$DIST_DIR/python311.arm64.zip
PY311_DIST_X86_64=$DIST_DIR/python311.x86_64.zip

PY312_DIST_ARM64=$DIST_DIR/python312.arm64.zip
PY312_DIST_X86_64=$DIST_DIR/python312.x86_64.zip

PY313_DIST_ARM64=$DIST_DIR/python313.arm64.zip
PY313_DIST_X86_64=$DIST_DIR/python313.x86_64.zip

NODE18_DIST_ARM64=$DIST_DIR/nodejs18x.arm64.zip
NODE18_DIST_X86_64=$DIST_DIR/nodejs18x.x86_64.zip

NODE20_DIST_ARM64=$DIST_DIR/nodejs20x.arm64.zip
NODE20_DIST_X86_64=$DIST_DIR/nodejs20x.x86_64.zip

NODE22_DIST_ARM64=$DIST_DIR/nodejs22x.arm64.zip
NODE22_DIST_X86_64=$DIST_DIR/nodejs22x.x86_64.zip

REGIONS_X86=(us-west-2)
REGIONS_ARM=(us-west-2)

EXTENSION_DIST_DIR=extensions
EXTENSION_DIST_ZIP=extension.zip
EXTENSION_DIST_PREVIEW_FILE=preview-extensions-ggqizro707

TMP_ENV_FILE_NAME=nr_tmp_env.sh

function fetch_extension {
    arch=$1
    url="https://github.com/newrelic/newrelic-lambda-extension/releases/download/v2.3.22/newrelic-lambda-extension.${arch}.zip"
    rm -rf $EXTENSION_DIST_DIR $EXTENSION_DIST_ZIP
    curl -L $url -o $EXTENSION_DIST_ZIP
}

function download_extension {
    if [ "$NEWRELIC_LOCAL_TESTING" = "true" ]; then
        case "$1" in
            "x86_64")
                echo "Locally building x86_64 extension"
                make -C ../ dist-x86_64
                ;;
            "arm64")
                echo "Locally building arm64 extension"
                make -C ../ dist-arm64
                ;;
            *)
                echo "No matching architecture"
                return 1 
                ;;
        esac
        cp -r ../extensions .
    else
        fetch_extension "$@"
        unzip "$EXTENSION_DIST_ZIP" -d .
        rm -f "$EXTENSION_DIST_ZIP"
    fi
}

function layer_name_str() {
    rt_part="Custom"
    arch_part=""

    case $1 in
    "python3.11")
      rt_part="Python311"
      ;;
    "python3.12")
      rt_part="Python312"
      ;;
    "nodejs18.x")
      rt_part="Nodejs18"
      ;;
    "nodejs20.x")
      rt_part="Nodejs20"
      ;;
    "nodejs22.x")
      rt_part="Nodejs22"
      ;;
    esac

    case $2 in
    "arm64")
      arch_part="ARM64"
      ;;
    "x86_64")
      arch_part="X86"
      ;;
    esac

    echo "NRTestExtension${rt_part}${arch_part}"
}


function hash_file() {
    if command -v md5sum &> /dev/null ; then
        md5sum $1 | awk '{ print $1 }'
    else
        md5 -q $1
    fi
}


function s3_prefix() {
    name="nr-test-extension"

    case $1 in
    "python3.11")
      name="nr-python3.11"
      ;;
    "python3.12")
      name="nr-python3.12"
      ;;
    "nodejs18.x")
      name="nr-nodejs18.x"
      ;;
    "nodejs20.x")
      name="nr-nodejs20.x"
      ;;
    "nodejs22.x")
      name="nr-nodejs22.x"
      ;;
    esac

    echo $name
}

function publish_layer {
    layer_archive=$1
    region=$2
    runtime_name=$3
    arch=$4

    layer_name=$( layer_name_str $runtime_name $arch )

    hash=$( hash_file $layer_archive | awk '{ print $1 }' )

    bucket_name="${BUCKET_PREFIX}-${region}"
    s3_key="$( s3_prefix $runtime_name )/${hash}.${arch}.zip"

    echo "Uploading ${layer_archive} to s3://${bucket_name}/${s3_key}"
    aws --region "$region" s3 cp $layer_archive "s3://${bucket_name}/${s3_key}"

    echo "Publishing ${runtime_name} layer to ${region}"
    layer_output=$(aws lambda publish-layer-version \
      --layer-name ${layer_name} \
      --content "S3Bucket=${bucket_name},S3Key=${s3_key}" \
      --description "New Relic Test Layer for ${runtime_name} (${arch})" \
      --license-info "Apache-2.0" \
      --region "$region" \
      --output json)

    layer_version=$(echo $layer_output | jq -r '.Version')
    layer_arn=$(echo $layer_output | jq -r '.LayerArn')

    echo "Published ${runtime_name} layer version ${layer_version} to ${region}"
    echo "Layer ARN: ${layer_arn}"
    full_layer_arn="${layer_arn}:${layer_version}"

    echo "Published ${runtime_name} layer version ${layer_version} to ${region}"
    echo "Full Layer ARN with version: ${full_layer_arn}"

    arch_upper=$(echo "$arch" | tr '[:lower:]' '[:upper:]')
    runtime_nodots=$(echo "${runtime_name//./}" | tr '[:lower:]' '[:upper:]')

    env_var_name="LAYER_ARN_${arch_upper}_${runtime_nodots}"
    echo $env_var_name
    declare "$env_var_name=$full_layer_arn"

    echo "export $env_var_name='$full_layer_arn'" >> $TMP_ENV_FILE_NAME
}

function make_package_json {
cat <<EOM >fake-package.json
{
  "name": "newrelic-esm-lambda-wrapper",
  "type": "module"
}
EOM
}


function build_python_version {
    version=$1
    arch=$2
    dist_dir=$3

    echo "Building New Relic layer for python$version ($arch)"
    rm -rf $BUILD_DIR $dist_dir
    mkdir -p $DIST_DIR
    pip3 install --no-cache-dir -qU newrelic newrelic-lambda -t $BUILD_DIR/lib/python$version/site-packages
    cp newrelic_lambda_wrapper.py $BUILD_DIR/lib/python$version/site-packages/newrelic_lambda_wrapper.py
    find $BUILD_DIR -name '__pycache__' -exec rm -rf {} +
    download_extension $arch
    zip -rq $dist_dir $BUILD_DIR $EXTENSION_DIST_DIR 
    rm -rf $BUILD_DIR $EXTENSION_DIST_DIR
    echo "Build complete: ${dist_dir}"
}

function publish_python_version {
    dist_dir=$1
    arch=$2
    version=$3
    regions=("${@:4}")

    if [ ! -f $dist_dir ]; then
        echo "Package not found: ${dist_dir}"
        exit 1
    fi

    for region in "${regions[@]}"; do
        publish_layer $dist_dir $region python$version $arch
    done
}

function build_nodejs_version {
    version=$1
    arch=$2
    dist_dir=$3

    echo "Building New Relic layer for nodejs${version}.x ($arch)"
    rm -rf $NODEJS_BUILD_DIR $dist_dir
    mkdir -p $DIST_DIR
    
    # Install New Relic Node.js agent (this creates nodejs/node_modules structure)
    npm install --prefix $NODEJS_BUILD_DIR newrelic@latest
    
    # Get the New Relic agent version for metadata
    NEWRELIC_AGENT_VERSION=$(npm list newrelic --prefix $NODEJS_BUILD_DIR | grep newrelic@ | awk -F '@' '{print $2}')
    touch $DIST_DIR/nr-env
    echo "NEWRELIC_AGENT_VERSION=$NEWRELIC_AGENT_VERSION" > $DIST_DIR/nr-env
    
    # Create wrapper directories and copy files (now from local_testing directory)
    mkdir -p $NODEJS_BUILD_DIR/node_modules/newrelic-lambda-wrapper
    cp index.js $NODEJS_BUILD_DIR/node_modules/newrelic-lambda-wrapper
    mkdir -p $NODEJS_BUILD_DIR/node_modules/newrelic-esm-lambda-wrapper
    cp esm.mjs $NODEJS_BUILD_DIR/node_modules/newrelic-esm-lambda-wrapper/index.js
    
    # Create ESM package.json
    make_package_json
    cp fake-package.json $NODEJS_BUILD_DIR/node_modules/newrelic-esm-lambda-wrapper/package.json
    
    download_extension $arch
    zip -rq $dist_dir $NODEJS_BUILD_DIR $EXTENSION_DIST_DIR 
    rm -rf fake-package.json $NODEJS_BUILD_DIR $EXTENSION_DIST_DIR
    echo "Build complete: ${dist_dir}"
}

function publish_nodejs_version {
    dist_dir=$1
    arch=$2
    version=$3
    regions=("${@:4}")

    if [ ! -f $dist_dir ]; then
        echo "Package not found: ${dist_dir}"
        exit 1
    fi

    # Source the environment file to get NEWRELIC_AGENT_VERSION
    source $DIST_DIR/nr-env

    for region in "${regions[@]}"; do
        publish_layer $dist_dir $region nodejs${version}.x $arch
    done
}

function build_extension_version {
    arch=$1
    dist_dir=$2

    echo "Building New Relic Lambda Extension Layer (x86_64)"
    rm -rf $DIST_DIR
    mkdir -p $DIST_DIR
    download_extension $arch
    zip -rq $dist_dir $EXTENSION_DIST_DIR 
    # rm -rf $EXTENSION_DIST_DIR
    echo "Build complete: ${dist_dir}"
}

function publish_extension_version {
    dist_dir=$1
    arch=$2
    regions=("${@:3}")

    if [ ! -f $dist_dir ]; then
        echo "Package not found: ${dist_dir}"
        exit 1
    fi

    for region in "${regions[@]}"; do
        publish_layer $dist_dir $region extension $arch
    done
}


if [ -f "$TMP_ENV_FILE_NAME" ]; then
    echo "Deleting tmp env file"
    rm -r "$TMP_ENV_FILE_NAME"
else
    echo "File $TMP_ENV_FILE_NAME does not exist."
fi


# Build and publish for python3.11 arm64
echo "Building and publishing for Python 3.11 ARM64..."
build_python_version "3.11" "arm64" $PY311_DIST_ARM64
publish_python_version $PY311_DIST_ARM64 "arm64" "3.11" "${REGIONS_ARM[@]}"

# Build and publish for python3.11 x86_64
echo "Building and publishing for Python 3.11 x86_64..."
build_python_version "3.11" "x86_64" $PY311_DIST_X86_64
publish_python_version $PY311_DIST_X86_64 "x86_64" "3.11" "${REGIONS_X86[@]}"

# Build and publish for python3.12 arm64
echo "Building and publishing for Python 3.12 ARM64..."
build_python_version "3.12" "arm64" $PY312_DIST_ARM64
publish_python_version $PY312_DIST_ARM64 "arm64" "3.12" "${REGIONS_ARM[@]}"

# Build and publish for python3.12 x86_64
echo "Building and publishing for Python 3.12 x86_64..."
build_python_version "3.12" "x86_64" $PY312_DIST_X86_64
publish_python_version $PY312_DIST_X86_64 "x86_64" "3.12" "${REGIONS_X86[@]}"

# Build and publish for python3.13 arm64
echo "Building and publishing for Python 3.13 ARM64..."
build_python_version "3.13" "arm64" $PY313_DIST_ARM64
publish_python_version $PY313_DIST_ARM64 "arm64" "3.13" "${REGIONS_ARM[@]}"

# Build and publish for python3.13 x86_64
echo "Building and publishing for Python 3.13 x86_64..."
build_python_version "3.13" "x86_64" $PY313_DIST_X86_64
publish_python_version $PY313_DIST_X86_64 "x86_64" "3.13" "${REGIONS_X86[@]}"

# Build and publish for nodejs18.x arm64
echo "Building and publishing for Node.js 18.x ARM64..."
build_nodejs_version "18" "arm64" $NODE18_DIST_ARM64
publish_nodejs_version $NODE18_DIST_ARM64 "arm64" "18.x" "${REGIONS_ARM[@]}"

# Build and publish for nodejs18.x x86_64
echo "Building and publishing for Node.js 18.x x86_64..."
build_nodejs_version "18" "x86_64" $NODE18_DIST_X86_64
publish_nodejs_version $NODE18_DIST_X86_64 "x86_64" "18.x" "${REGIONS_X86[@]}"

# Build and publish for nodejs20.x arm64
echo "Building and publishing for Node.js 20.x ARM64..."
build_nodejs_version "20" "arm64" $NODE20_DIST_ARM64
publish_nodejs_version $NODE20_DIST_ARM64 "arm64" "20.x" "${REGIONS_ARM[@]}"

# Build and publish for nodejs20.x x86_64
echo "Building and publishing for Node.js 20.x x86_64..."
build_nodejs_version "20" "x86_64" $NODE20_DIST_X86_64
publish_nodejs_version $NODE20_DIST_X86_64 "x86_64" "20.x" "${REGIONS_X86[@]}"

# Build and publish for nodejs22.x arm64
echo "Building and publishing for Node.js 22.x ARM64..."
build_nodejs_version "22" "arm64" $NODE22_DIST_ARM64
publish_nodejs_version $NODE22_DIST_ARM64 "arm64" "22.x" "${REGIONS_ARM[@]}"

# Build and publish for nodejs22.x x86_64
echo "Building and publishing for Node.js 22.x x86_64..."
build_nodejs_version "22" "x86_64" $NODE22_DIST_X86_64
publish_nodejs_version $NODE22_DIST_X86_64 "x86_64" "22.x" "${REGIONS_X86[@]}"

# Build and publish for Extension ARM64
echo "Building and publishing for Extension ARM64..."
build_extension_version "arm64" $EXTENSION_DIST_ZIP_ARM64
publish_extension_version $EXTENSION_DIST_ZIP_ARM64 "arm64" "${REGIONS_ARM[@]}"

# Build and publish for Extension x86_64
echo "Building and publishing for Extension x86_64..."
build_extension_version "x86_64" $EXTENSION_DIST_ZIP_X86_64
publish_extension_version $EXTENSION_DIST_ZIP_X86_64 "x86_64" "${REGIONS_X86[@]}"
