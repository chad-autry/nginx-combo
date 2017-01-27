#!/bin/bash

for file in /units/**/*
do
  fleetctl destroy "$file"
done
