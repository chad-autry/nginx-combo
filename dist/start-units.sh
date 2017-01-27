#!/bin/bash

for file in /units/**/*
do
  fleetctl submit "$file"
done
for file in /units/started/*
do
  fleetctl start "$file"
done
