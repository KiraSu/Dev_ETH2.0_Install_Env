#!/bin/bash
this_hostname=$(hostname)
sudo yum install -y git gcc g++ make pkg-config llvm-dev libclang-dev clang openssl-devel go
wget https://github.com/Kitware/CMake/releases/download/v3.24.1/cmake-3.24.1.tar.gz
tar -zxf cmake-3.24.1.tar.gz && cd cmake-3.24.1 && ./bootstrap && make -j8 && sudo make install
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
cd $HOME && rm -r cmake-3.24.1 && rm cmake-3.24.1.tar.gz
if [[ $this_hostname == *"lighthouse"* ]]; then
  git clone https://github.com/sigp/lighthouse.git && cd lighthouse && git checkout stable && make -j8
fi

if [[ $this_hostname == *"geth"* ]]; then
  git clone https://github.com/ethereum/go-ethereum.git && cd go-ethereum && git checkout v1.10.23 && make -j8
fi
