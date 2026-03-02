#!/bin/bash
# startup script: runs every time the VM is created.

set -e

# Install packages
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git

