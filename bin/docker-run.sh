#!/bin/bash

set -eux

docker run --rm -it -v "$PWD:/app" -p 5006:5006 metacpan/metacpan-api-v0-shim:latest
