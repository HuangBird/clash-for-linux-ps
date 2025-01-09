#!/bin/bash

#################### Root Privilege Check ####################

if [[ $EUID -ne 0 ]]; then
   echo -e "\\033[1;31mThis script must be run as root\\033[0m" 1>&2
   exit 1
fi

#################### Script Initialization ####################

# Get absolute path of script directory
export Server_Dir=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)

# Load .env variables
source $Server_Dir/.env

# Set execute permissions
chmod +x $Server_Dir/bin/*
chmod +x $Server_Dir/scripts/*
chmod +x $Server_Dir/tools/subconverter/subconverter

#################### Variable Setup ####################

Conf_Dir="$Server_Dir/conf"
Log_Dir="$Server_Dir/logs"

# Get or generate Secret
Secret=${CLASH_SECRET:-$(openssl rand -hex 32)}

#################### Functions ####################

# Custom action functions
success() {
    echo -en "\\033[60G[\\033[1;32m  OK  \\033[0;39m]\r"
    return 0
}

failure() {
    local rc=$?
    echo -en "\\033[60G[\\033[1;31mFAILED\\033[0;39m]\r"
    return $rc
}

action() {
    local STRING rc
    STRING=$1
    echo -n "$STRING "
    shift
    "$@" && success $"$STRING" || failure $"$STRING"
    rc=$?
    echo
    return $rc
}

# Add new validation function
validate_clash_config() {
    local config_file=$1
    local raw_content=$(cat "$config_file")
    
    # First check if content is standard clash format
    if echo "$raw_content" | awk '/^proxies:/{p=1} /^proxy-groups:/{g=1} /^rules:/{r=1} p&&g&&r{exit} END{if(p&&g&&r) exit 0; else exit 1}'; then
        echo -e "\033[32mConfiguration file is in standard Clash format\033[0m"
        return 0
    else
        # Check if content is base64 encoded
        if echo "$raw_content" | base64 -d &>/dev/null; then
            echo -e "\033[33mConfig appears to be base64 encoded, attempting to decode...\033[0m"
            decoded_content=$(echo "$raw_content" | base64 -d)
            
            # Check if decoded content is valid clash config
            if echo "$decoded_content" | awk '/^proxies:/{p=1} /^proxy-groups:/{g=1} /^rules:/{r=1} p&&g&&r{exit} END{if(p&&g&&r) exit 0; else exit 1}'; then
                echo -e "\033[32mDecoded content is valid Clash format\033[0m"
                echo "$decoded_content" > "$config_file.decoded"
                mv "$config_file.decoded" "$config_file"
                return 0
            else
                echo -e "\033[31mError: Decoded content is not a valid Clash configuration\033[0m"
                return 1
            fi
        else
            echo -e "\033[31mError: Invalid Clash configuration format\033[0m"
            echo -e "File must contain the following required sections:"
            echo -e "  - proxies:"
            echo -e "  - proxy-groups:"
            echo -e "  - rules:"
            return 1
        fi
    fi
}

#################### Configuration File Input ####################

# Prompt for configuration file
while true; do
    echo -e "\nPlease enter the name of your Clash configuration file (including extension):"
    read config_file

    # Check if file exists
    if [ -f "$config_file" ]; then
        echo -e "\nValidating configuration file: $config_file"
        if validate_clash_config "$config_file"; then
            echo -e "\033[32mConfiguration file is valid!\033[0m"
            break
        else
            echo -e "\033[31mError: Invalid Clash configuration file format!\033[0m"
            echo "File must contain 'proxies:', 'proxy-groups:', and 'rules:' sections"
            continue
        fi
    else
        echo -e "\n\033[31mError: File '$config_file' not found in current directory!\033[0m"
        echo "Available yaml/yml files in current directory:"
        ls -1 *.{yaml,yml} 2>/dev/null || echo "No yaml/yml files found"
        echo -e "Please try again...\n"
    fi
done

#################### Main Tasks ####################

# Get CPU architecture
source $Server_Dir/scripts/get_cpu_arch.sh

# Check if CPU architecture was obtained
if [[ -z "$CpuArch" ]]; then
    echo "Failed to obtain CPU architecture"
    exit 1
fi

# Copy your existing configuration file to the required location
echo -e '\nCopying configuration file...'
\cp -f $config_file $Conf_Dir/config.yaml

# Configure Clash Dashboard
Work_Dir=$(cd $(dirname $0); pwd)
Dashboard_Dir="${Work_Dir}/dashboard/public"
sed -ri "s@^# external-ui:.*@external-ui: ${Dashboard_Dir}@g" $Conf_Dir/config.yaml
sed -r -i '/^secret: /s@(secret: ).*@\1'${Secret}'@g' $Conf_Dir/config.yaml

# Start Clash Service
echo -e '\nStarting Clash service...'
Text5="Service started successfully!"
Text6="Service failed to start!"

if [[ $CpuArch =~ "x86_64" || $CpuArch =~ "amd64"  ]]; then
    nohup $Server_Dir/bin/clash-linux-amd64 -d $Conf_Dir &> $Log_Dir/clash.log &
    ReturnStatus=$?
elif [[ $CpuArch =~ "aarch64" ||  $CpuArch =~ "arm64" ]]; then
    nohup $Server_Dir/bin/clash-linux-arm64 -d $Conf_Dir &> $Log_Dir/clash.log &
    ReturnStatus=$?
elif [[ $CpuArch =~ "armv7" ]]; then
    nohup $Server_Dir/bin/clash-linux-armv7 -d $Conf_Dir &> $Log_Dir/clash.log &
    ReturnStatus=$?
else
    echo -e "\033[31m\n[ERROR] Unsupported CPU Architecture！\033[0m"
    exit 1
fi

if [ $ReturnStatus -eq 0 ]; then
    action "$Text5" /bin/true
else
    action "$Text6" /bin/false
    exit 1
fi

# Output Dashboard access information
echi '+----------------------------------------------------+'
echo ''
echo -e "Clash Dashboard access address: http://<ip>:9090/ui"
echo -e "Secret: ${Secret}"
echo ''

# Add environment variables (root privileges required)
cat>/etc/profile.d/clash.sh<<EOF
# Enable system proxy
function proxy_on() {
    export http_proxy=http://127.0.0.1:7890
    export https_proxy=http://127.0.0.1:7890
    export no_proxy=127.0.0.1,localhost
    export HTTP_PROXY=http://127.0.0.1:7890
    export HTTPS_PROXY=http://127.0.0.1:7890
    export NO_PROXY=127.0.0.1,localhost
    echo -e "\033[32m[√] Proxy enabled\033[0m"
}

# Disable system proxy
function proxy_off(){
    unset http_proxy
    unset https_proxy
    unset no_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset NO_PROXY
    echo -e "\033[31m[×] Proxy disabled\033[0m"
}
EOF

echo -e "Please execute the following command to load environment variables: source /etc/profile.d/clash.sh\n"
echo -e "Please execute the following command to enable system proxy: proxy_on\n"
echo -e "To temporarily disable system proxy, execute: proxy_off\n"
