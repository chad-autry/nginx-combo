#!/bin/bash

find ./units -type f -exec fleetctl load {} \;
find ./units/started -type f -exec fleetctl start {} \;
