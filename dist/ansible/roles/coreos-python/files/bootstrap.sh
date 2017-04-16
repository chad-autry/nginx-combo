#/bin/bash

set -e

cd

if [[ -e /opt/bin/python ]]; then
  exit 0
fi

PYPY_VERSION=5.1.0

if [[ -e $HOME/pypy-$PYPY_VERSION-linux64.tar.bz2 ]]; then
  tar -xjf $HOME/pypy-$PYPY_VERSION-linux64.tar.bz2
  rm -rf $HOME/pypy-$PYPY_VERSION-linux64.tar.bz2
else
  wget -O - https://bitbucket.org/pypy/pypy/downloads/pypy-$PYPY_VERSION-linux64.tar.bz2 |tar -xjf -
fi

mkdir -p /opt/bin

mv -n pypy-$PYPY_VERSION-linux64 /opt/bin/pypy

## library fixup
mkdir -p /opt/pypy/lib
ln -snf /lib64/libncurses.so.5.9 /opt/pypy/lib/libtinfo.so.5

cat > /opt/bin/python <<EOF
#!/bin/bash
LD_LIBRARY_PATH=/opt/bin/pypy/lib:$LD_LIBRARY_PATH exec /opt/bin/pypy/bin/pypy "\$@"
EOF

chmod +x /opt/bin/python
/opt/bin/python --version
