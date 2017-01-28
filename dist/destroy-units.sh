#!/bin/bash

find ./units -type f -exec fleetctl destroy {} \;
