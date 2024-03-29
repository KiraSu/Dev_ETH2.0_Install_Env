#!/bin/bash

#goerli
#mainnet/goerli
NETWORK=mainnet
#Product/Dev
ENV=Product
INSTANCE_TYPE=c7g.xlarge
#https://goerli.checkpoint-sync.ethdevops.io
#https://mainnet-checkpoint-sync.stakely.io
BEACON_NODE_CHECKPOINT_URL="https://sync-mainnet.beaconcha.in"
#0xb5a2e1614127adbce67f35a0dec134891e6ea021f82b4cc48419012e1a8f10bd93094062f28fc928f4c8967920c49948
VALIDATOR_MONITOR_PUBKEY=

ARCHI=$(uname -m)
EC2_Info=
RUN_DIR=$(pwd)
LIGHTHOUSE_CONFIG_JSON=
GETH_ENDPOINT=
GETH_JWT_SECRECT=
declare -l MetaModuleName=
ModuleRunCMD=
RemoteEC2Result=
RES_TAG_ATTR=("ResourceType=instance,Tags=[{Key=Name,Value=${ENV}ETH2.0_Geth_${NETWORK}}]" "ResourceType=instance,Tags=[{Key=Name,Value=${ENV}ETH2.0_Lighthouse_${NETWORK}}]")
EBS_JSON="[\
    {\
        \"DeviceName\": \"/dev/xvda\",\
        \"Ebs\": {\
            \"VolumeType\": \"gp3\",\
            \"VolumeSize\": 64\
        }\
    },\
    {\
	\"DeviceName\": \"/dev/sdf\",\
        \"Ebs\": {\
            \"VolumeType\": \"st1\",\
            \"VolumeSize\": 512\
        }\
    },\
    {\
        \"DeviceName\": \"/dev/sdg\",\
        \"Ebs\": {\
            \"VolumeType\": \"st1\",\
            \"VolumeSize\": 512\
        }\
    }\
]"
CMAKE_VERSION=3.24.1
GETH_TAG_VERSION=v1.11.6

create_ec2_instance() {
    echo $EBS_JSON > $RUN_DIR/ebs_mapping.json
    RemoteEC2Result=$(aws ec2 run-instances --no-cli-page --image-id $(echo $EC2_Info | jq -r '.[0].ImageId') --count 1 --instance-type $1 --key-name $(echo $EC2_Info | jq -r '.[0].KeyName') --security-group-ids $(echo $EC2_Info | jq -r '.[0].GroupId') --subnet-id $(echo $EC2_Info | jq -r '.[0].SubnetId') --associate-public-ip-address --block-device-mappings file://$RUN_DIR/ebs_mapping.json --tag-specifications $2)
    echo "RemoteEC2Result: $RemoteEC2Result"
    if [ $? -ne 0 ]; then
        echo "create_ec2_instance failed: $RemoteEC2Result"
	exit 0
    fi
    
    EC2InstanceId=$(echo $RemoteEC2Result | jq -r '.Instances[0].InstanceId')
    echo "Waiting EC2[$EC2InstanceId] status running..."
    EC2WaitRunning=$(aws ec2 wait instance-running --instance-ids $EC2InstanceId)
    sleep 5s
}

sudo yum update -y
sudo yum install -y git gcc g++ make pkg-config llvm-dev libclang-dev clang openssl-devel go jq

###### Install AWS Cli
if command -v aws &> /dev/null
then
    ###### aws-cli/2.7.31 Python/3.9.11 Linux/5.10.130-118.517.amzn2.aarch64 exe/aarch64.amzn.2 prompt/off
    if [ $(which aws) = "/usr/bin/aws" ]; then
	echo "Upgrade AWS Cli..."
        cd $HOME && curl "https://awscli.amazonaws.com/awscli-exe-linux-$ARCHI.zip" -o "awscliv2.zip" && unzip awscliv2.zip && sudo ./aws/install
        rm -r aws && rm awscliv2.zip
    fi
else
    echo "Install AWS Cli...."
    cd $HOME && curl "https://awscli.amazonaws.com/awscli-exe-linux-$ARCHI.zip" -o "awscliv2.zip" && unzip awscliv2.zip && sudo ./aws/install
    rm -r aws && rm awscliv2.zip
fi

###### Check cmake
if ! command -v cmake &> /dev/null
then
    cd $HOME
    wget https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION.tar.gz
    tar -zxf cmake-$CMAKE_VERSION.tar.gz && cd cmake-$CMAKE_VERSION && ./bootstrap && make -j8 && sudo make install
    cd $HOME && sudo rm -r cmake-$CMAKE_VERSION && sudo rm cmake-$CMAKE_VERSION.tar.gz
fi

#Check rust
if ! command -v rustc &> /dev/null
then
    cd $HOME && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs >> rust.sh && sudo chmod a+x rust.sh && ./rust.sh -y
    source "$HOME/.cargo/env" && rm rust.sh
fi

###### Get this ec2 instance info
EC2_InfoCMD=$(echo "aws ec2 describe-instances --no-cli-page --query 'Reservations[*].Instances[?contains(InstanceId,\`$(curl http://169.254.169.254/latest/meta-data/instance-id)\`)]|[].{InstanceType:InstanceType,InstanceId:InstanceId,ImageId:ImageId,KeyName:KeyName,AvailabilityZone:Placement.AvailabilityZone,VpcId:VpcId,SubnetId:SubnetId,GroupId:NetworkInterfaces[0].Groups[0].GroupId}'")
echo $EC2_InfoCMD
EC2_Info=$(eval $EC2_InfoCMD)
if [ $? -ne 0 ]; then
    echo "Get EC2 Info failed."
    echo "EC2_Info: ${EC2_Info}"
    exit 0
fi
echo "EC2_Info: ${EC2_Info}"

####### Build geth
if [ ! -d "$HOME/go-ethereum" ]; then
    cd $HOME && git clone https://github.com/ethereum/go-ethereum.git
fi
cd $HOME/go-ethereum && git checkout $GETH_TAG_VERSION && make all -j8

###### Build lighthouse
if [ ! -d "$HOME/lighthouse" ]; then
    cd $HOME && git clone https://github.com/sigp/lighthouse.git && cd $HOME/lighthouse && git checkout stable && make -j8
else
    cd $HOME/lighthouse
#    if [ $(git log stable -n 1 --pretty=format:"%H") = $(git log remotes/origin/stable -n 1 --pretty=format:"%H") ]; then
#        echo "Lighthouse nothing change"
#    else
#        git pull && make -j8
#    fi
fi
git checkout stable && make -j8


for tagValue in ${RES_TAG_ATTR[@]}
do
MetaModuleName=$(echo "$tagValue" | cut -d '_' -f 2)
EC2ConfigName=${MetaModuleName}_${NETWORK}_ec2_instance.json
###### Create Geth/Lighthouse EC2 Instance if not exist [geth(lighthouse)_ec2_instance.json] otherwise load the [geth(lighthouse)_ec2_instance.json] file to upgrade geth service
if [ ! -f "$HOME/$EC2ConfigName" ]; then
    ###### Call create EC2 instance
    create_ec2_instance $INSTANCE_TYPE $tagValue
    echo $RemoteEC2Result > $HOME/$EC2ConfigName
    
    RemoteEC2IpAddr="$(echo $RemoteEC2Result | jq -r '.Instances[0].PrivateIpAddress')"
    RemoteSSH="ssh -i $RUN_DIR/key.pem ec2-user@$RemoteEC2IpAddr"
    
    ###### Init the extend disk
    RemoteCMDExe="$RemoteSSH 'sudo yum update -y && sudo mkdir -p /var/lib/${MetaModuleName} && sudo pvcreate /dev/nvme1n1 && sudo vgcreate vg_default /dev/sdf && sudo lvcreate -l 100%VG -n lv_data vg_default && sudo mkfs.ext4 /dev/vg_default/lv_data && sudo mount -t ext4 /dev/vg_default/lv_data /var/lib/${MetaModuleName} && echo \"/dev/mapper/vg_default-lv_data /var/lib/${MetaModuleName} ext4 defaults 0 0\" | sudo tee -a /etc/fstab'"
    echo $RemoteCMDExe
    eval $RemoteCMDExe
else
    RemoteEC2Result=$(cat $HOME/$EC2ConfigName)
    RemoteEC2IpAddr="$(echo $RemoteEC2Result | jq -r '.Instances[0].PrivateIpAddress')"
    RemoteSSH="ssh -i $RUN_DIR/key.pem ec2-user@$RemoteEC2IpAddr"
fi

###### Stop geth/lighthouse service
RemoteCMDExe="$RemoteSSH 'while systemctl is-active ${MetaModuleName} &>/dev/null ;do sudo systemctl stop ${MetaModuleName} && sleep 3s;done'"
echo $RemoteCMDExe
eval $RemoteCMDExe

###### Fill geth/lighthouse ModuleRunCMD
if [[ $MetaModuleName == "geth" ]]; then
    ModuleRunCMD="/usr/local/bin/${MetaModuleName} --${NETWORK} --http --http.addr 0.0.0.0 --authrpc.addr 0.0.0.0 --metrics --metrics.addr 0.0.0.0 --metrics.expensive --ws --ws.addr 0.0.0.0 --datadir /var/lib/${MetaModuleName}/.${MetaModuleName}/${NETWORK} --txlookuplimit 0"
else
    LighthouseJWTSecrectDir=/var/lib/${MetaModuleName}/.${MetaModuleName}/${NETWORK}
    ModuleRunCMD="/usr/local/bin/${MetaModuleName} -d $LighthouseJWTSecrectDir --network ${NETWORK} bn --checkpoint-sync-url=$BEACON_NODE_CHECKPOINT_URL --http --http-address 0.0.0.0 --metrics --metrics-address 0.0.0.0 --execution-endpoint http://$GETH_ENDPOINT --execution-jwt $LighthouseJWTSecrectDir/jwtsecret --validator-monitor-auto"
    if [ -n "$VALIDATOR_MONITOR_PUBKEY" ]; then
        ModuleRunCMD+=" --validator-monitor-pubkeys $VALIDATOR_MONITOR_PUBKEY"
    fi
    RemoteCMDExe="$RemoteSSH 'sudo mkdir -p $LighthouseJWTSecrectDir && echo $GETH_JWT_SECRECT | sudo tee $LighthouseJWTSecrectDir/jwtsecret > /dev/null'"
    echo $RemoteCMDExe
    eval $RemoteCMDExe
fi

###### Create service config file
RemoteCMDExe="$RemoteSSH 'echo -e [Unit]\\\\nDescription=${MetaModuleName} Execution Client\\\\nWants=network.target\\\\nAfter=network.target\\\\n\\\\n[Service]\\\\nUser=${MetaModuleName}\\\\nGroup=${MetaModuleName}\\\\nType=simple\\\\nRestart=always\\\\nRestartSec=5\\\\nExecStart=${ModuleRunCMD}\\\\n\\\\n[Install]\\\\nWantedBy=default.target\\\\n | sudo tee /etc/systemd/system/${MetaModuleName}.service > /dev/null'"
echo $RemoteCMDExe
eval $RemoteCMDExe

###### Add 'geth/lighthouse' user and change owner /var/lib/geth(lighthouse)
RemoteCMDExe="$RemoteSSH 'if id -u $MetaModuleName >/dev/null 2>&1; then echo ok; else sudo useradd --no-create-home --shell /bin/false ${MetaModuleName}; fi && sudo chown -R ${MetaModuleName}:${MetaModuleName} /var/lib/${MetaModuleName}'"
echo $RemoteCMDExe
eval $RemoteCMDExe

###### Copy all Geth/Lighthouse bin file to remote ec2 /usr/local/bin
RemoteCMDExe="$RemoteSSH '[ -d $HOME/${MetaModuleName} ] && echo ok || mkdir -p $HOME/${MetaModuleName}'"
echo $RemoteCMDExe
eval $RemoteCMDExe
if [ $? -eq 0 ]; then
    if [[ -z $GETH_JWT_SECRECT ]]; then
        RemoteCMDExe="scp -i $RUN_DIR/key.pem $HOME/go-ethereum/build/bin/* ec2-user@$RemoteEC2IpAddr:~/${MetaModuleName}"
    else
	RemoteCMDExe="scp -i $RUN_DIR/key.pem $HOME/${MetaModuleName}/target/release/${MetaModuleName} ec2-user@$RemoteEC2IpAddr:~/${MetaModuleName}"
    fi
    echo $RemoteCMDExe
    eval $RemoteCMDExe
    
    RemoteCMDExe="$RemoteSSH 'sudo cp ~/${MetaModuleName}/* /usr/local/bin'"
    echo $RemoteCMDExe
    eval $RemoteCMDExe
    
    RemoteCMDExe="$RemoteSSH 'sudo systemctl daemon-reload && sudo systemctl start ${MetaModuleName} && sudo systemctl status ${MetaModuleName}'"
    echo $RemoteCMDExe
    eval $RemoteCMDExe

    if [[ $MetaModuleName == "geth" ]]; then
	echo "Waiting $MetaModuleName service start..."
        sleep 5s
        RemoteCMDExe="$RemoteSSH 'sudo cat /var/lib/${MetaModuleName}/.${MetaModuleName}/${NETWORK}/${MetaModuleName}/jwtsecret'"
	echo $RemoteCMDExe
	GETH_JWT_SECRECT=$(eval $RemoteCMDExe)
	GETH_ENDPOINT="$RemoteEC2IpAddr:8551"
    fi
fi

done

