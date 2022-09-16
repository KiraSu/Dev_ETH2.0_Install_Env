#!/bin/bash

THIS_HOSTNAME=$(hostname)
SUB_HOSTNAME_LIGHTHOUSE=lighthouse
SUB_HOSTNAME_GETH=geth
CURRENT_HOST_CLIENT=
CMAKE_VERSION=3.24.1
GETH_TAG_VERSION=v1.10.23

#############################################################################
#NETWORK=goerli
#Consensus Client Config
#BEACON_NODE_CHECKPOINT_URL=https://goerli.checkpoint-sync.ethdevops.io
#EXECUTION_ENDPOINT=172.31.15.113
#EXECUTION_JWTSECRET=0xd80f0ed48f72a86c2288035fd4b121f4c82634e4681f3f34859d8998eadc3609
#############################################################################

echo "NETWORK: $NETWORK"
echo "BEACON_NODE_CHECKPOINT_URL: $BEACON_NODE_CHECKPOINT_URL"
echo "EXECUTION_ENDPOINT: $EXECUTION_ENDPOINT"
echo "EXECUTION_JWTSECRET: $EXECUTION_JWTSECRET"

sudo yum update -y
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
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs >> rust.sh && sudo chmod a+x rust.sh && ./rust.sh -y
	source "$HOME/.cargo/env" && rm rust.sh
    fi

    #Create 'lighthouse' user for system service
    if id "$SUB_HOSTNAME_LIGHTHOUSE" &>/dev/null; then
        echo "User ${SUB_HOSTNAME_LIGHTHOUSE}"
    else
	echo "Creating User ${SUB_HOSTNAME_LIGHTHOUSE}"
        sudo useradd --no-create-home --shell /bin/false $SUB_HOSTNAME_LIGHTHOUSE
    fi
    
    if [[ $(systemctl is-active $SUB_HOSTNAME_LIGHTHOUSE) == "active" ]]; then
        sudo systemctl stop $SUB_HOSTNAME_LIGHTHOUSE
    fi
    
    #Build lighthouse
    if [ ! -d "$HOME/lighthouse" ]; then
        cd $HOME && git clone https://github.com/sigp/lighthouse.git
    fi
    cd $HOME/lighthouse && git checkout stable && make -j8 && sudo cp ./target/release/lighthouse /usr/local/bin
    
    #Set JWTSecrect
    if [[ $EXECUTION_JWTSECRET = "" ]]
    then
        EXECUTION_JWTSECRET=$HOME/data/.ethereum/goerli/geth/jwtsecret
    else
	echo -e "${EXECUTION_JWTSECRET}" | sudo tee /var/lib/lighthouse/.lighthouse/${NETWORK}/jwtsecret > /dev/null
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
ExecStart=/usr/local/bin/lighthouse -d /var/lib/lighthouse/.lighthouse/${NETWORK} --network ${NETWORK} bn --checkpoint-sync-url=${BEACON_NODE_CHECKPOINT_URL} --http --execution-endpoint http://${EXECUTION_ENDPOINT}:8551 --execution-jwt /var/lib/lighthouse/.lighthouse/${NETWORK}/jwtsecret\n\n\
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
sudo mkdir -p /var/lib/$CURRENT_HOST_CLIENT

#Create pv vg lv
sudo pvcreate /dev/nvme1n1
sudo vgcreate vg_default /dev/sdf
sudo lvcreate -l 100%VG -n lv_data vg_default
sudo mkfs.ext4 /dev/vg_default/lv_data
sudo mount -t ext4 /dev/vg_default/lv_data /var/lib/$CURRENT_HOST_CLIENT
echo "/dev/mapper/vg_default-lv_data /var/lib/geth ext4 defaults 0 0" | sudo tee -a /etc/fstab

sudo chown -R $CURRENT_HOST_CLIENT:$CURRENT_HOST_CLIENT /var/lib/${CURRENT_HOST_CLIENT}

sudo systemctl daemon-reload
sudo systemctl start $CURRENT_HOST_CLIENT
sudo systemctl status $CURRENT_HOST_CLIENT


