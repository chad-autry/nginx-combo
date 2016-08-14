#!/bin/bash
set -ev;
git init
git config user.name ${GH_NAME}
git config user.email ${GH_EMAIL}
git add .
git add -u .
git commit -a -m "Automated push of generated files  [ci skip]"
git push --force --quiet "https://${GH_TOKEN}@${GH_REF}"  master > /dev/null 2>&1