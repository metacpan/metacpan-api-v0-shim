#!/bin/bash

set -eux

docker build -t metacpan/metacpan-api-v0-shim:latest .
