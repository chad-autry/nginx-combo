#!/bin/bash

find ./units -type f -exec fleetctl submit {} \;
find ./units/started -type f -exec fleetctl start {} \
