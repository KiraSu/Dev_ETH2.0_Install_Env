#!/bin/bash

THIS_HOSTNAME=$(hostname)
SUB_HOSTNAME_LIGHTHOUSE=lighthouse
SUB_HOSTNAME_GETH=geth
CURRENT_HOST_CLIENT=
CMAKE_VERSION=3.24.1
GETH_TAG_VERSION=v1.10.23

#############################################################################
NETWORK=goerli
#Consensus Client Config
BEACON_NODE_CHECKPOINT_URL=https://goerli.checkpoint-sync.ethdevops.io
EXECUTION_ENDPOINT=127.0.0.1
EXECUTION_JWTSECRET=
#############################################################################

sudo yum install -y git gcc g++ make pkg-config llvm-dev libclang-dev clang openssl-devel go

#Check cmake
if ! command -v cmake &> /dev/null
then
    cd $HOME
    wget https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION.tar.gz
    tar -zxf cmake-$CMAKE_VERSION.tar.gz && cd cmake-$CMAKE_VERSION && ./bootstrap && make -j8 && sudo make install
    cd $HOME && sudo rm -r cmake-$CMAKE_VERSION && sudo rm cmake-$CMAKE_VERSION.tar.gz
fi

if [[ $THIS_HOSTNAME == *"$SUB_HOSTNAME_LIGHTHOUSE"* ]]; then
    CURRENT_HOST_CLIENT=$SUB_HOSTNAME_LIGHTHOUSE

    #Check rust
    if ! command -v rustc &> /dev/null
    then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
    fi

    #Create 'lighthouse' user for system service
    if id "$SUB_HOSTNAME_LIGHTHOUSE" &>/dev/null; then
        echo "User ${SUB_HOSTNAME_LIGHTHOUSE}"
    else
	echo "Creating User ${SUB_HOSTNAME_LIGHTHOUSE}"
        sudo useradd --no-create-home --shell /bin/false $SUB_HOSTNAME_LIGHTHOUSE
        mkdir -p $HOME/data
        sudo chown -R $SUB_HOSTNAME_LIGHTHOUSE:$SUB_HOSTNAME_LIGHTHOUSE $HOME/data
    fi
    
    if [[ $(systemctl is-active $SUB_HOSTNAME_LIGHTHOUSE) == "active" ]]; then
        sudo systemctl stop $SUB_HOSTNAME_LIGHTHOUSE
    fi
    
    #Build lighthouse
    if [ ! -d "$HOME/lighthouse" ]; then
        cd $HOME && git clone https://github.com/sigp/lighthouse.git
    fi
    cd $HOME/lighthouse && git checkout stable && make -j8 && cp ./target/release/lighthouse /usr/local/bin
    
    #Set JWTSecrect
    if [[ $EXECUTION_JWTSECRET = "" ]]
    then
        EXECUTION_JWTSECRET=$HOME/data/.ethereum/goerli/geth/jwtsecret
    else
        echo -e ${EXECUTION_JWTSECRET} > $HOME/data/.lighthouse/${NETWORK}/jwtsecret
	EXECUTION_JWTSECRET=$HOME/data/.lighthouse/${NETWORK}/jwtsecret
    fi

    #Add System Service
    echo -e "[Unit]\n\
Description=Lighthouse Consensus Client (${NETWORK} Network)\n\
Wants=network.target\n\
After=network.target\n\n\
[Service]\n\
User=${SUB_HOSTNAME_LIGHTHOUSE}\n\
Group=${SUB_HOSTNAME_LIGHTHOUSE}\n\
Type=simple\n\
Restart=always\n\
RestartSec=5\n\
ExecStart=/usr/local/bin/lighthouse -d $HOME/data/.lighthouse/${NETWORK} --network ${NETWORK} bn --checkpoint-sync-url=${BEACON_NODE_CHECKPOINT_URL} --http --execution-endpoint http://${EXECUTION_ENDPOINT}:8551 --execution-jwt $HOME/data/.lighthouse/${NETWORK}/jwtsecret\n\n\
[Install]\n\
WantedBy=default.target\n" | sudo tee /etc/systemd/system/${SUB_HOSTNAME_LIGHTHOUSE}.service > /dev/null
elif [[ $THIS_HOSTNAME == *"$SUB_HOSTNAME_GETH"* ]]; then
    CURRENT_HOST_CLIENT=$SUB_HOSTNAME_GETH

    #Create 'geth' user for system service
    if id "$SUB_HOSTNAME_GETH" &>/dev/null; then
        echo "User ${SUB_HOSTNAME_GETH}"
    else
	echo "Creating User ${SUB_HOSTNAME_GETH}"
        sudo useradd --no-create-home --shell /bin/false $SUB_HOSTNAME_GETH
    fi
    
    if [[ $(systemctl is-active $SUB_HOSTNAME_GETH) == "active" ]]; then
        sudo systemctl stop $SUB_HOSTNAME_GETH
    fi
    
    #Build geth
    if [ ! -d "$HOME/go-ethereum" ]; then
        cd $HOME && git clone https://github.com/ethereum/go-ethereum.git
    fi
    cd $HOME/go-ethereum && git checkout $GETH_TAG_VERSION && make all -j8 && sudo cp ./build/bin/* /usr/local/bin

    echo -e "[Unit]\n\
Description=Geth Execution Client (${NETWORK} Network)\n\
Wants=network.target\n\
After=network.target\n\n\
[Service]\n\
User=${SUB_HOSTNAME_GETH}\n\
Group=${SUB_HOSTNAME_GETH}\n\
Type=simple\n\
Restart=always\n\
RestartSec=5\n\
ExecStart=/usr/local/bin/geth --${NETWORK} --http --http.addr 0.0.0.0 --authrpc.addr 0.0.0.0 --datadir /var/lib/${CURRENT_HOST_CLIENT}/.ethereum/${NETWORK}\n\n\
[Install]\n\
WantedBy=default.target\n" | sudo tee /etc/systemd/system/${SUB_HOSTNAME_GETH}.service > /dev/null
else
    echo "Unknow hostname: ${THIS_HOSTNAME}"
    exit -1
fi

#Create Geth/Lightouse data director
if [ ! -d "/var/lib/${CURRENT_HOST_CLIENT}" ]; then
    sudo mkdir -p /var/lib/$CURRENT_HOST_CLIENT
    sudo chown -R $CURRENT_HOST_CLIENT:$CURRENT_HOST_CLIENT /var/lib/${CURRENT_HOST_CLIENT}
fi

sudo systemctl daemon-reload
sudo systemctl start $CURRENT_HOST_CLIENT
sudo systemctl status $CURRENT_HOST_CLIENT


